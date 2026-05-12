import Foundation
import os
import Combine
#if canImport(IOBluetooth)
import IOBluetooth
#endif

/// Port of `src/server/nocturne-manager.ts` — owns the RPCClient instance per
/// connected Car Thing, handles the built-in RPC methods the daemon expects,
/// and forwards inbound events from the daemon back up to the UI layer.
@MainActor
final class RPCManager: ObservableObject {
    private let log = Log.make(for: "RPCManager")
    private let nowPlaying: NowPlayingService
    private let spotify: SpotifyService
    private let api = APIClient()
    #if canImport(IOBluetooth)
    private let localSpotify = SpotifyAppleScriptReader()
    #endif

    @Published private(set) var deviceInfo: CarThingInfo? = nil
    @Published private(set) var lastPing: Date? = nil

    private struct Connection {
        let address: String
        #if canImport(IOBluetooth)
        weak var channel: IOBluetoothRFCOMMChannel?
        #endif
        let client: RPCClient
    }

    private var connections: [String: Connection] = [:]
    private var keepAliveTask: Task<Void, Never>?
    private var stateBroadcastTask: Task<Void, Never>?
    private var lastBroadcastTrack: String? = nil
    private var lastBroadcastIsPlaying: Bool? = nil

    /// Pending volume value the Car Thing wheel keeps changing; coalesced and
    /// sent in a single Web API call after a brief quiet window so we don't
    /// flood Spotify (which rate-limits at ~ten requests per second).
    private var pendingVolumeTarget: Int? = nil
    private var volumeDebounceTask: Task<Void, Never>? = nil

    private var stateObservation: AnyCancellable?

    init(spotify: SpotifyService, nowPlaying: NowPlayingService) {
        self.spotify = spotify
        self.nowPlaying = nowPlaying
        // Push a fresh broadcast whenever the track state changes — instead of
        // waiting for the next 1.5s poll tick, the Car Thing sees track skips
        // within ~100ms of the actual change.
        //
        // Important: deduplicate by track identity only (NOT isPlaying).
        // MediaRemote oscillates `isPlaying` true/false/true on a single track
        // many times — each bounce used to invalidate the /me/player cache and
        // force a fresh fetch, which Spotify rate-limits aggressively. The
        // isPlaying flag is reliable straight from MediaRemote; we can keep
        // serving the cached cluster and just update locally.
        stateObservation = nowPlaying.$state
            .removeDuplicates { a, b in
                a.trackName == b.trackName && a.artistName == b.artistName
            }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Real track change → server-side state has moved on, so
                    // drop the cache and let the next broadcast pick up the
                    // new cluster from Spotify. isPlaying-only flips skip this.
                    self?.invalidatePlayerStateCache()
                    await self?.broadcastSpotifyState(reason: "PLAYER_STATE_CHANGED", force: true)
                }
            }
    }

    // MARK: - Channel attach/detach

    #if canImport(IOBluetooth)
    func attach(channel: IOBluetoothRFCOMMChannel, address: String) {
        let key = channelKey(address: address, channel: channel)
        if connections[key] != nil { return }

        let client = RPCClient(id: key)
        client.onCall = { [weak self] method, params in
            await self?.handleCall(method: method, params: params) ?? (nil, "manager gone")
        }
        client.onEvent = { [weak self] topic, data in
            self?.handleEvent(topic: topic, data: data, address: address)
        }
        client.onWrite = { [weak channel] data in
            guard let channel else { return }
            // Only skip when the channel itself is closed. Don't also check
            // `device.isConnected()` — that flag is unreliable for the
            // Car-Thing-dialed-in case and returns false even when the RFCOMM
            // pipe is alive, which would silently drop every outbound event
            // (broadcasts, RPC responses, etc.). A spurious API-MISUSE warning
            // from the kernel after a real disconnect is the lesser evil.
            guard channel.isOpen() else { return }
            data.withUnsafeBytes { buf in
                let ptr = UnsafeMutableRawPointer(mutating: buf.baseAddress!)
                _ = channel.writeSync(ptr, length: UInt16(data.count))
            }
        }

        connections[key] = Connection(address: address, channel: channel, client: client)
        log.info("RPC client attached: \(key, privacy: .public)")

        startKeepAliveIfNeeded()
        startStateBroadcastIfNeeded()

        // Ask the Car Thing for its device.info so the Dashboard row can show
        // firmware / serial / git hash. `nocturned` doesn't implement a `ping`
        // RPC — the Pi's old initial-ping handshake just timed out here, blocked
        // device.info from ever being asked, and printed a misleading "handshake
        // failed" warning. The real handshake (daemon.ready ← → app.ready) is
        // handled separately in the daemon.ready event handler.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.fetchDeviceInfo(key: key)
        }
    }

    func ingest(_ data: Data, channel: IOBluetoothRFCOMMChannel, address: String) {
        let key = channelKey(address: address, channel: channel)
        if let conn = connections[key] {
            Task { @MainActor in await conn.client.ingest(data) }
        } else {
            // Channel arrived before attach; cache + late-attach.
            attach(channel: channel, address: address)
            if let conn = connections[key] {
                Task { @MainActor in await conn.client.ingest(data) }
            }
        }
    }

    func detach(channel: IOBluetoothRFCOMMChannel, address: String) {
        let key = channelKey(address: address, channel: channel)
        if let conn = connections.removeValue(forKey: key) {
            conn.client.cleanup()
            log.info("RPC client detached: \(key, privacy: .public)")
        }
        if connections.isEmpty {
            stopKeepAlive()
            stopStateBroadcast()
        }
    }

    private func channelKey(address: String, channel: IOBluetoothRFCOMMChannel) -> String {
        "\(address)#\(channel.getID())"
    }
    #endif

    /// True when there's *some* Spotify source we can drive — either Spotify Web
    /// OAuth was completed in the Mac app, or Spotify.app is running locally
    /// (and we can bridge via AppleScript). Either way the Car Thing should
    /// leave its "needs auth" QR-code screen.
    private var isSpotifyBridged: Bool {
        if spotify.authState.isLinked { return true }
        #if canImport(IOBluetooth)
        return localSpotify.isAvailable
        #else
        return false
        #endif
    }

    // MARK: - Built-in RPC method handlers (Mac side)

    private func handleCall(method: String, params: MessagePackValue) async -> (result: MessagePackValue?, error: String?) {
        switch method {
        case "ping":
            let message = params.mapValue("message")?.stringValue ?? "pong"
            return (.map([(.string("pong"), .string(message))]), nil)
        case "device.info":
            return (.map([
                (.string("device"), .string("nocturne-connector-mac")),
                (.string("version"), .string("1.0.0"))
            ]), nil)
        case "spotify.auth.getStatus":
            // We bridge the Car Thing through our local Spotify.app via
            // AppleScript instead of doing Web-API OAuth. As long as a local
            // Spotify instance is reachable, advertise authenticated=true so
            // the Car Thing leaves its QR-code "needs auth" screen.
            return (.map([
                (.string("authenticated"), .bool(isSpotifyBridged)),
                (.string("skipped"), .bool(false))
            ]), nil)
        case "device.time.get":
            return (.map(currentTimeMap()), nil)
        case "device.timezone.get":
            return (.map(currentTimezoneMap()), nil)

        // --- Spotify player surface ---
        // Route through the Spotify Web API when the user's account is linked;
        // fall back to the local Spotify.app bridge (MediaController/AppleScript)
        // only when no Web token is available. Web API is the canonical control
        // path — it works for Spotify Connect, populates the firmware's cluster
        // state correctly, and isn't gated by macOS Automation permission.
        case "spotify.player.state":
            // Prefer the live cluster from Spotify so the firmware gets every
            // field it indexes into (context_uri, restrictions, options, real
            // track URIs). The synthesized fallback is missing those fields,
            // which is why the Car Thing renders blank when we serve it.
            if let cluster = await fetchSpotifyWebPlayerState() {
                return (cluster, nil)
            }
            return (spotifyPlayerState(), nil)
        case "spotify.player.play", "spotify.player.resume":
            let viaWeb = await spotifyWebTransport(path: "play", method: "PUT")
            if !viaWeb { await nowPlaying.play() }
            await pushFreshStateAfterTransport(isPlayingHint: true)
            return (.bool(true), nil)
        case "spotify.player.pause":
            let viaWeb = await spotifyWebTransport(path: "pause", method: "PUT")
            if !viaWeb { await nowPlaying.pause() }
            await pushFreshStateAfterTransport(isPlayingHint: false)
            return (.bool(true), nil)
        case "spotify.player.toggle", "spotify.player.playPause", "spotify.player.togglePlayPause":
            // Toggle has no direct Web endpoint — derive from current state and
            // call play or pause explicitly. Use the freshest Web /me/player
            // when available so we don't flip the wrong direction.
            let wasPlaying = await currentlyPlayingPerWeb() ?? nowPlaying.state.isPlaying
            let path = wasPlaying ? "pause" : "play"
            let viaWeb = await spotifyWebTransport(path: path, method: "PUT")
            if !viaWeb { await nowPlaying.togglePlayPause() }
            await pushFreshStateAfterTransport(isPlayingHint: !wasPlaying)
            return (.bool(true), nil)
        case "spotify.player.next", "spotify.player.skipNext":
            let viaWeb = await spotifyWebTransport(path: "next", method: "POST")
            if !viaWeb { await nowPlaying.next() }
            await pushFreshStateAfterTransport(isPlayingHint: true)
            return (.bool(true), nil)
        case "spotify.player.previous", "spotify.player.skipPrevious":
            let viaWeb = await spotifyWebTransport(path: "previous", method: "POST")
            if !viaWeb { await nowPlaying.previous() }
            await pushFreshStateAfterTransport(isPlayingHint: true)
            return (.bool(true), nil)
        case "spotify.player.setVolume", "spotify.player.volume", "device.volume.set":
            // Log the raw params first so we can see whatever shape the Car Thing
            // is actually sending. The Pi connector accepts a handful of keys
            // (volume, value, level, percent, volumePercent) — try them all.
            let dump = describe(params)
            log.info("volume RPC params: \(dump, privacy: .public)")
            let candidates = ["volume", "value", "level", "percent", "volumePercent",
                              "volume_percent", "volumeLevel"]
            var pct: Int? = nil
            for key in candidates {
                if let v = params.mapValue(key) {
                    if case .double(let d) = v {
                        pct = Int(d > 1 ? d : d * 100)
                    } else if let i = v.intValue {
                        pct = i > 1 ? i : i * 100
                    }
                    if pct != nil { break }
                }
            }
            // If the call is just an integer/double payload (no map), use that.
            if pct == nil {
                if case .int(let i) = params { pct = Int(i) }
                if case .uint(let u) = params { pct = Int(u) }
                if case .double(let d) = params { pct = Int(d > 1 ? d : d * 100) }
            }
            if let pct {
                queueVolumeChange(pct)
            } else {
                log.warning("volume RPC: couldn't parse a percent out of params")
            }
            return (.bool(true), nil)
        case "spotify.player.seek", "device.seek":
            if let positionMs = (params.mapValue("position") ?? params.mapValue("positionMs"))?.intValue {
                nowPlaying.seek(positionMs: positionMs)
            }
            return (.bool(true), nil)

        // --- Car Thing hardware-button namespace ---
        case "media.control.volumeUp", "media.control.volume_up":
            nowPlaying.bumpVolume(by: +5)
            return (.bool(true), nil)
        case "media.control.volumeDown", "media.control.volume_down":
            nowPlaying.bumpVolume(by: -5)
            return (.bool(true), nil)
        case "media.control.play":
            await nowPlaying.play()
            return (.bool(true), nil)
        case "media.control.pause":
            await nowPlaying.pause()
            return (.bool(true), nil)
        case "media.control.togglePlayPause", "media.control.toggle_play_pause":
            await nowPlaying.togglePlayPause()
            return (.bool(true), nil)
        case "media.control.next", "media.control.skip":
            await nowPlaying.next()
            return (.bool(true), nil)
        case "media.control.previous", "media.control.prev":
            await nowPlaying.previous()
            return (.bool(true), nil)

        // --- Shuffle / repeat (the Car Thing's mode pickers) ---
        case "spotify.player.shuffle":
            let shuffleOn = parseBool(params.mapValue("state")) ?? parseBool(params.mapValue("shuffle")) ?? false
            nowPlaying.setShuffle(shuffleOn)
            return (.bool(true), nil)
        case "spotify.player.repeat":
            let mode = params.mapValue("state")?.stringValue
                ?? params.mapValue("mode")?.stringValue
                ?? "off"
            nowPlaying.setRepeat(mode: mode)
            return (.bool(true), nil)
        case "spotify.me.profile":
            // Real profile from /v1/me when linked; cached so repeated calls
            // from the Car Thing's UI don't re-hit Spotify.
            return await proxyWebGet(path: "me")
        case "spotify.me.recentlyPlayed":
            let limit = params.mapValue("limit")?.intValue ?? 20
            return await proxyWebGet(path: "me/player/recently-played?limit=\(limit)")
        case "spotify.me.topArtists":
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            return await proxyWebGet(path: "me/top/artists?limit=\(limit)&offset=\(offset)")
        case "spotify.me.topTracks":
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            return await proxyWebGet(path: "me/top/tracks?limit=\(limit)&offset=\(offset)")
        case "spotify.me.shows":
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            return await proxyWebGet(path: "me/shows?limit=\(limit)&offset=\(offset)")
        case "spotify.me.albums", "spotify.me.savedAlbums":
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            return await proxyWebGet(path: "me/albums?limit=\(limit)&offset=\(offset)")
        case "spotify.me.episodes":
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            return await proxyWebGet(path: "me/episodes?limit=\(limit)&offset=\(offset)")
        case "spotify.radio.mixes":
            // Daily Mixes are exposed through a private endpoint we don't
            // have access to. Return an empty list so the firmware renders
            // an empty "Mixes" row rather than a perpetual loading spinner.
            return (.map([(.string("items"), .array([]))]), nil)
        case "spotify.library.songs",
             "spotify.library.albums",
             "spotify.library.artists",
             "spotify.library.playlists":
            // Empty list — Car Thing renders an empty section instead of errors.
            return (.array([]), nil)

        // --- Image fetch: Car Thing asks us to download album art for it ---
        // The firmware expects { data: <base64 string>, contentType, size }
        // (see Pi connector's `handleFetchImage`). Returning the raw bytes
        // as a msgpack binary blob looks like it works — no error — but the
        // firmware's `atob` path silently fails to decode it, so the image
        // never renders.
        case "spotify.image.fetch":
            guard let urlStr = params.mapValue("url")?.stringValue,
                  let url = URL(string: urlStr) else {
                return (.nilValue, "missing or invalid 'url' param")
            }
            do {
                let (data, http) = try await api.request(url, method: "GET")
                guard (200..<300).contains(http.statusCode) else {
                    log.warning("spotify.image.fetch HTTP \(http.statusCode, privacy: .public) for \(urlStr, privacy: .public)")
                    return (.nilValue, "image fetch HTTP \(http.statusCode)")
                }
                // Must return base64 STRING (not msgpack `bin`). The Car
                // Thing's nocturned daemon converts msgpack → JSON before
                // handing the message to the UI WebView (the UI parses with
                // `JSON.parse(event.data)`). JSON has no binary type, so
                // msgpack-bin values become either a number-array or a
                // `{type:"Buffer",data:[...]}` object — neither of which
                // matches the firmware's `imageData instanceof Uint8Array`
                // check. A base64 string survives JSON intact and hits the
                // firmware's `typeof imageData === "string"` branch, which
                // builds the data: URL it can actually render.
                let base64 = data.base64EncodedString()
                log.info("spotify.image.fetch ok: \(data.count, privacy: .public) bytes (b64 \(base64.count, privacy: .public)) from \(urlStr, privacy: .public)")
                return (.map([
                    (.string("data"), .string(base64)),
                    (.string("contentType"), .string(http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg")),
                    (.string("size"), .int(Int64(data.count)))
                ]), nil)
            } catch {
                log.warning("spotify.image.fetch failed for \(urlStr, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return (.nilValue, "image fetch failed: \(error.localizedDescription)")
            }

        // --- Album / playlist / user-library queries (proxy to Spotify Web API) ---
        case "spotify.album.get":
            return await proxyWebGet(path: "albums/\(params.mapValue("id")?.stringValue ?? "")")
        case "spotify.album.tracks":
            let id = params.mapValue("id")?.stringValue ?? ""
            let limit = params.mapValue("limit")?.intValue ?? 50
            return await proxyWebGet(path: "albums/\(id)/tracks?limit=\(limit)")
        case "spotify.playlist.get":
            let id = params.mapValue("id")?.stringValue ?? ""
            let fields = params.mapValue("fields")?.stringValue
            var path = "playlists/\(id)"
            if let fields, let escaped = fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                path += "?fields=\(escaped)"
            }
            return await proxyWebGet(path: path)
        case "spotify.playlist.tracks":
            let id = params.mapValue("id")?.stringValue ?? ""
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            let fields = params.mapValue("fields")?.stringValue
            var path = "playlists/\(id)/tracks?limit=\(limit)&offset=\(offset)"
            if let fields, let escaped = fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                path += "&fields=\(escaped)"
            }
            return await proxyWebGet(path: path)
        case "spotify.me.tracks.contains":
            // "Is each of these tracks saved in the user's library?" — drives
            // the heart/save indicator on the player UI. Spotify returns an
            // array of booleans matching the input `ids` order.
            let ids = (params.mapValue("ids")?.arrayValue ?? [])
                .compactMap { $0.stringValue }
                .joined(separator: ",")
            guard !ids.isEmpty else { return (.array([]), nil) }
            let escaped = ids.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ids
            return await proxyWebGet(path: "me/tracks/contains?ids=\(escaped)")
        case "spotify.me.albums.contains":
            let ids = (params.mapValue("ids")?.arrayValue ?? [])
                .compactMap { $0.stringValue }
                .joined(separator: ",")
            guard !ids.isEmpty else { return (.array([]), nil) }
            let escaped = ids.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ids
            return await proxyWebGet(path: "me/albums/contains?ids=\(escaped)")
        case "spotify.me.tracks", "spotify.me.savedTracks":
            let limit = params.mapValue("limit")?.intValue ?? 20
            let offset = params.mapValue("offset")?.intValue ?? 0
            return await proxyWebGet(path: "me/tracks?limit=\(limit)&offset=\(offset)")
        case "spotify.me.playlists":
            let limit = params.mapValue("limit")?.intValue ?? 20
            return await proxyWebGet(path: "me/playlists?limit=\(limit)")
        case "spotify.artist.get":
            return await proxyWebGet(path: "artists/\(params.mapValue("id")?.stringValue ?? "")")
        case "spotify.search":
            let q = params.mapValue("query")?.stringValue ?? params.mapValue("q")?.stringValue ?? ""
            let type = params.mapValue("type")?.stringValue ?? "track,album,artist,playlist"
            if let qEsc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let tEsc = type.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                return await proxyWebGet(path: "search?q=\(qEsc)&type=\(tEsc)&limit=20")
            }
            return (.array([]), nil)
        case "spotify.devices", "spotify.player.devices", "spotify.device.list":
            // Advertise the Mac itself as the single active Spotify Connect
            // device. Without this the Car Thing's UI gets stuck in a "discover
            // devices" loop and won't dispatch play/pause via RPC — it keeps
            // trying to send commands to a remote Connect device that doesn't
            // exist on our auth. Marking ourselves "is_active = true" and
            // "is_restricted = true" tells nocturned to route commands through
            // RPC instead of Spotify Connect cloud.
            let macDevice: MessagePackValue = .map([
                (.string("id"), .string("mac-local")),
                (.string("name"), .string(Host.current().localizedName ?? "Mac")),
                (.string("type"), .string("Computer")),
                (.string("is_active"), .bool(true)),
                (.string("is_private_session"), .bool(false)),
                (.string("is_restricted"), .bool(true)),
                (.string("supports_volume"), .bool(true)),
                (.string("volume_percent"), .int(50))
            ])
            return (.map([(.string("devices"), .array([macDevice]))]), nil)

        default:
            let p = describe(params)
            log.warning("Unhandled RPC method: \(method, privacy: .public)  params=\(p, privacy: .public)")
            return (.nilValue, nil)
        }
    }

    /// Returns a minimal "now playing" snapshot in the shape the Car Thing
    /// expects (see how the Pi connector's spotify-service forwards
    /// `connect_state_native` payloads). On macOS we don't have a full Spotify
    /// Web API client wired up, so we read from the local Spotify.app via
    /// AppleScript and translate.
    private func spotifyPlayerState() -> MessagePackValue {
        // Return the same Spotify-cluster-shaped payload we push via
        // `spotify.player.state_changed`. Some Car Thing builds read the RPC
        // reply, others the broadcast — using one consistent shape avoids the
        // mismatch.
        return buildSpotifyClusterEvent(snap: nowPlaying.state, reason: "PLAYER_STATE_CHANGED")
    }

    // MARK: - Inbound events from the daemon

    private func handleEvent(topic: String, data: MessagePackValue, address: String) {
        log.info("daemon → topic=\(topic, privacy: .public)")
        switch topic {
        case "daemon.ready":
            Task { @MainActor in await broadcastAppReady() }
        default:
            // Future: hook spotify.command.* events to NowPlayingService here.
            break
        }
    }

    // MARK: - Post-attach device info

    /// Best-effort `device.info` fetch right after a channel attaches. The
    /// real handshake (Car Thing → daemon.ready, us → app.ready) is driven
    /// from the event handler — we don't gate anything on this call. If
    /// nocturned doesn't answer, the Dashboard just won't show firmware
    /// metadata; everything else keeps working.
    private func fetchDeviceInfo(key: String) async {
        guard let conn = connections[key] else { return }
        do {
            let info = try await conn.client.call(method: "device.info", params: .map([]), timeout: 5)
            log.info("device.info ← \(self.describe(info), privacy: .public)")
            deviceInfo = parseDeviceInfo(info)
            lastPing = Date()
        } catch {
            log.info("device.info unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Send the `app.ready` event the Car Thing's UI waits for before showing
    /// the player. Without this, the daemon stays in the "not playing" state.
    private func broadcastAppReady() async {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        var utcCal = calendar
        utcCal.timeZone = utc
        let pad: (Int) -> String = { String(format: "%02d", $0) }
        let yc = utcCal.component(.year, from: now)
        let mo = utcCal.component(.month, from: now)
        let dy = utcCal.component(.day, from: now)
        let hh = utcCal.component(.hour, from: now)
        let mi = utcCal.component(.minute, from: now)
        let ss = utcCal.component(.second, from: now)
        let datetime = "\(yc)-\(pad(mo))-\(pad(dy)) \(pad(hh)):\(pad(mi)):\(pad(ss))"
        let localCal = calendar
        let lh = localCal.component(.hour, from: now)
        let lm = localCal.component(.minute, from: now)
        let ls = localCal.component(.second, from: now)
        let timeStr = "\(pad(lh)):\(pad(lm)):\(pad(ls))"

        let tz = TimeZone.current
        let tzID = tz.identifier
        let offset = tz.secondsFromGMT(for: now)
        let abbr = tz.abbreviation(for: now) ?? ""
        let isDst = tz.isDaylightSavingTime(for: now)

        let appReady: MessagePackValue = .map([
            // Mirror the Pi's payload exactly — the Car Thing UI gates some
            // behavior on platform=="web" and won't recognize "mac".
            (.string("platform"), .string("web")),
            (.string("timestamp"), .int(Int64(now.timeIntervalSince1970 * 1000))),
            (.string("spotifySkipped"), .bool(false)),
            (.string("datetime"), .string(datetime)),
            (.string("time"), .string(timeStr)),
            (.string("timezone"), .map([
                (.string("identifier"), .string(tzID)),
                (.string("secondsFromGMT"), .int(Int64(offset))),
                (.string("abbreviation"), .string(abbr)),
                (.string("isDaylightSavingTime"), .bool(isDst))
            ]))
        ])

        let spotifyStatus: MessagePackValue = .map([
            (.string("authenticated"), .bool(isSpotifyBridged)),
            (.string("skipped"), .bool(false))
        ])

        for (_, conn) in connections {
            await conn.client.sendEvent(topic: "spotify.auth.status", data: spotifyStatus)
            await conn.client.sendEvent(topic: "app.ready", data: appReady)
        }
        log.info("Sent app.ready to \(self.connections.count, privacy: .public) device(s)")
    }

    // MARK: - Keep-alive

    private func startKeepAliveIfNeeded() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                guard let self else { return }
                // nocturned has no `ping` RPC, so we don't actively probe —
                // RFCOMM's link-layer keep-alive plus its socket-close
                // notification are enough to notice a dead peer. We use this
                // tick only to detach stale entries whose underlying channel
                // has already closed (handleChannelClosed should have done
                // this, but on some failure modes the close callback is
                // missed and the entry lingers).
                #if canImport(IOBluetooth)
                let stale = self.connections.filter { _, conn in
                    // `channel` is weak — nil means the channel object was
                    // released without a close callback firing.
                    conn.channel?.isOpen() != true
                }
                for (key, conn) in stale {
                    self.connections.removeValue(forKey: key)
                    conn.client.cleanup()
                    self.log.info("Keep-alive: pruned stale RPC entry \(key, privacy: .public)")
                }
                if self.connections.isEmpty {
                    self.lastPing = nil
                } else {
                    self.lastPing = Date()
                }
                #endif
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // MARK: - Spotify state broadcast (push player state events)
    //
    // The Car Thing's UI populates by listening for `spotify.player.state_changed`
    // events with a Spotify-cluster-shaped payload. The Pi connector receives
    // these from Spotify's WebSocket dealer; on macOS we synthesize an
    // equivalent from the local Spotify.app via AppleScript.

    private func startStateBroadcastIfNeeded() {
        guard stateBroadcastTask == nil else { return }
        log.info("Starting Spotify state broadcast loop")
        stateBroadcastTask = Task { [weak self] in
            // Announce connection established so the daemon transitions out of
            // "Spotify offline" state.
            await self?.sendConnectionEstablished()
            // Send an initial state immediately, then poll for changes.
            await self?.broadcastSpotifyState(reason: "PLAYER_STATE_CHANGED", force: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s — snappier
                await self?.broadcastSpotifyState(reason: "PLAYER_STATE_CHANGED", force: false)
            }
        }
    }

    private func stopStateBroadcast() {
        stateBroadcastTask?.cancel()
        stateBroadcastTask = nil
        lastBroadcastTrack = nil
        lastBroadcastIsPlaying = nil
    }

    private func sendConnectionEstablished() async {
        let connectionId = "mac-\(UUID().uuidString.lowercased())"
        let data: MessagePackValue = .map([
            (.string("connection_id"), .string(connectionId))
        ])
        for (_, conn) in connections {
            await conn.client.sendEvent(topic: "spotify.connection.established", data: data)
        }
    }

    private func broadcastSpotifyState(reason: String, force: Bool) async {
        // No connected Car Thing → no point burning a Web API call. Without
        // this guard, early MediaRemote state updates at app launch trigger
        // /me/player fetches that don't go anywhere, and the resulting 429s
        // poison Spotify's rate-limit window for the actual connection.
        if connections.isEmpty {
            return
        }
        // Prefer Spotify Web API's raw /v1/me/player payload — that's the
        // exact cluster shape the Car Thing UI is built for, with all the
        // fields (context_uri, repeat/shuffle, supported actions, etc.) that
        // the synthesized version is missing. Fall back to the synthesized
        // shape only when Web auth isn't linked.
        let snap = nowPlaying.state
        let trackKey = (snap.trackName ?? "") + "|" + (snap.artistName ?? "")
        let isPlaying = snap.isPlaying
        if !force, trackKey == lastBroadcastTrack, isPlaying == lastBroadcastIsPlaying {
            return
        }
        lastBroadcastTrack = trackKey
        lastBroadcastIsPlaying = isPlaying

        let payload: MessagePackValue
        if let webState = await fetchSpotifyWebPlayerState() {
            payload = webState
        } else {
            payload = buildSpotifyClusterEvent(snap: snap, reason: reason)
        }

        // The nocturne-ui firmware's `useSpotifyPlayerState` hook *only*
        // subscribes to `spotify.player.device_state_changed` for cluster
        // updates — sending PLAYER_STATE_CHANGED on `spotify.player.state_changed`
        // is ignored (the firmware has no listener for that topic). Always
        // broadcast on `device_state_changed` so the UI actually receives it.
        let topic = "spotify.player.device_state_changed"
        for (_, conn) in connections {
            await conn.client.sendEvent(topic: topic, data: payload)
        }
        log.info("Broadcast player state to \(self.connections.count, privacy: .public) device(s) on \(topic, privacy: .public): track=\(trackKey, privacy: .public) playing=\(isPlaying, privacy: .public)")
    }

    /// Wrapped `/v1/me/player` response. Spotify aggressively throttles
    /// repeat callers — recent builds burned through the quota and landed us
    /// in 30-60s `Retry-After` cooldowns. We lean on the cache hard now:
    ///
    /// - **Fresh** (`Date - fetchedAt < cacheTTL`): return cache, no network.
    /// - **Stale** (TTL expired OR invalidated by signal): attempt fresh fetch;
    ///   if cooldown active or fetch fails, return last-known-good cache
    ///   anyway. That keeps the Car Thing fed with a real cluster shape (with
    ///   all the fields the firmware indexes) even while we're being
    ///   throttled — much better than falling back to the synthesized payload
    ///   that's missing context_uri/restrictions/etc.
    private var cachedPlayerState: (payload: MessagePackValue, fetchedAt: Date)? = nil
    private var cacheNeedsRefresh: Bool = false
    private let playerStateCacheTTL: TimeInterval = 10.0

    /// Fetch the live `/v1/me/player` payload from Spotify and wrap it in the
    /// Pi connector's `cleanupWebSocketMessage`-style envelope. Returns nil
    /// only when the user has no linked Spotify account; otherwise serves the
    /// freshest available data (possibly stale during a cooldown).
    private func fetchSpotifyWebPlayerState() async -> MessagePackValue? {
        let isFresh: Bool = {
            guard let cached = cachedPlayerState else { return false }
            return !cacheNeedsRefresh
                && Date().timeIntervalSince(cached.fetchedAt) < playerStateCacheTTL
        }()
        if isFresh, let cached = cachedPlayerState {
            return cached.payload
        }
        guard let creds = SessionStore.shared.loadSpotifyCredentials() else {
            return cachedPlayerState?.payload
        }
        if Date() < webAPICooldownUntil {
            // Throttled; serve stale rather than nothing. The Car Thing's
            // firmware tolerates a slightly old cluster better than the
            // synthesized fallback (which it can't render at all).
            return cachedPlayerState?.payload
        }
        do {
            let (data, http) = try await api.request(
                URL(string: "https://api.spotify.com/v1/me/player")!,
                method: "GET",
                headers: ["Authorization": "Bearer \(creds.accessToken)"]
            )
            if http.statusCode == 204 { return nil }
            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) ?? 30
                webAPICooldownUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                // Log the raw body — Spotify often includes a JSON error
                // explaining whether this is a true rate limit vs a
                // token / scope / account issue masquerading as 429.
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("Web player-state 429 — retryAfter=\(retryAfter, privacy: .public)s body=\(body, privacy: .public)")
                return cachedPlayerState?.payload
            }
            if http.statusCode == 401 {
                // Access token expired/revoked. Try one refresh and retry once.
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("Web player-state 401 — token rejected. body=\(body, privacy: .public)")
                await spotify.bootstrap()
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("Web player-state HTTP \(http.statusCode, privacy: .public) body=\(body, privacy: .public)")
                return cachedPlayerState?.payload
            }
            // Decode the JSON. Spotify's REST `/me/player` shape is NOT what
            // the Car Thing firmware reads — the firmware was built around
            // Spotify's WebSocket Dealer cluster format (what the Pi connector
            // forwards). We have to transform the REST fields into the
            // cluster fields the Car Thing actually indexes.
            //
            //   REST `item.name`                  → cluster `track.metadata.title`
            //   REST `item.artists[0].name`       → cluster `track.metadata.artist_name`
            //   REST `item.album.name`            → cluster `track.metadata.album_title`
            //   REST `item.album.images[0].url`   → cluster `track.metadata.image_url`
            //   REST `item.uri`                   → cluster `track.uri` (real `spotify:track:...`)
            //   REST `item.duration_ms`           → cluster `track.metadata.duration`
            //   REST `progress_ms` (number)       → cluster `position_as_of_timestamp` (stringified)
            //   REST `is_playing`                 → cluster `is_playing` / `is_paused`
            //   REST `device.id`                  → cluster `active_device_id`
            //   REST `context.uri`                → cluster `context_uri`
            let json = try JSONSerialization.jsonObject(with: data)
            let restPlayer = MessagePackValue.wrap(json)
            let wrapped = await buildClusterFromRESTPlayer(restPlayer)
            cachedPlayerState = (wrapped, Date())
            cacheNeedsRefresh = false
            return wrapped
        } catch {
            // Network error — fall back to whatever we last had.
            return cachedPlayerState?.payload
        }
    }

    /// Mark the cached `/v1/me/player` response as needing a refresh on the
    /// next fetch. We do NOT nil it out — if the fetch then fails (cooldown,
    /// network error), the previous payload is still served so the Car Thing
    /// keeps rendering something coherent instead of falling back to the
    /// incomplete synthesized cluster.
    private func invalidatePlayerStateCache() {
        cacheNeedsRefresh = true
    }

    /// Returns the freshest `is_playing` flag we can get from Spotify Web —
    /// used by the `spotify.player.toggle` handler to pick whether to call
    /// `play` or `pause`. Returns nil if Spotify isn't linked or the API is
    /// in cooldown; the caller falls back to the local snapshot.
    private func currentlyPlayingPerWeb() async -> Bool? {
        guard SessionStore.shared.loadSpotifyCredentials() != nil else { return nil }
        if Date() < webAPICooldownUntil { return nil }
        guard let cluster = await fetchSpotifyWebPlayerState() else { return nil }
        // Walk payloads[0].cluster.player_state.is_playing
        let isPlaying = cluster
            .mapValue("payloads")?.arrayValue?.first?
            .mapValue("cluster")?
            .mapValue("player_state")?
            .mapValue("is_playing")?
            .boolValue
        return isPlaying
    }

    /// Per-image data-URL cache. Built by `buildClusterFromRESTPlayer` when
    /// it needs an inlined image — we want each unique remote image URL to
    /// be fetched and base64-encoded ONCE, then re-used on every subsequent
    /// cluster broadcast for the same track. Cleared when it grows past a
    /// few entries so we don't leak memory across many tracks.
    private var imageDataURLCache: [String: String] = [:]

    /// Fetch a Spotify image URL, base64-encode it, and return a fully-formed
    /// `data:image/jpeg;base64,<...>` URL. Returns nil on any error so the
    /// caller can fall back to the remote URL. Cached per remote URL.
    private func dataURLForImage(_ remoteURL: String) async -> String? {
        if let cached = imageDataURLCache[remoteURL] {
            return cached
        }
        guard let url = URL(string: remoteURL) else { return nil }
        do {
            let (data, http) = try await api.request(url, method: "GET")
            guard (200..<300).contains(http.statusCode) else { return nil }
            let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            // Keep the cache bounded — Spotify images don't change often
            // within a session, but over time tracks pile up.
            if imageDataURLCache.count > 32 {
                imageDataURLCache.removeAll()
            }
            imageDataURLCache[remoteURL] = dataURL
            return dataURL
        } catch {
            return nil
        }
    }

    /// Translate a Spotify REST `/v1/me/player` response (parsed JSON) into
    /// the Spotify Connect WebSocket cluster shape the Car Thing firmware
    /// reads. The firmware was built against the Pi connector's
    /// `cleanupWebSocketMessage` output — same envelope, but the player_state
    /// inside has WebSocket-style field names (track.metadata.title, etc.),
    /// not REST-style (item.name).
    private func buildClusterFromRESTPlayer(_ rest: MessagePackValue) async -> MessagePackValue {
        let item = rest.mapValue("item")
        let album = item?.mapValue("album")
        let artists = item?.mapValue("artists")?.arrayValue ?? []

        let title = item?.mapValue("name")?.stringValue ?? ""
        let artistName = artists.first?.mapValue("name")?.stringValue ?? ""
        let albumTitle = album?.mapValue("name")?.stringValue ?? ""
        // Spotify returns three image sizes (640/300/64). The Car Thing's
        // embedded WebView reliably renders the 64x64 size; 300x300 and
        // 640x640 silently fail at the color-extraction step (img.onload
        // never fires for ~30KB+ base64 data URLs in the WebView). 64x64
        // up-scales to the 280x280 slot — softer than ideal but actually
        // visible. TODO: progressive enhancement — serve 64x64 first then
        // swap in the medium image once we know it's safe.
        let imageList = album?.mapValue("images")?.arrayValue ?? []
        let remoteImageURL: String = {
            // Smallest first (height <= 100, picks the 64x64 thumbnail).
            for img in imageList {
                if let h = img.mapValue("height")?.intValue, h <= 100 {
                    return img.mapValue("url")?.stringValue ?? ""
                }
            }
            // Fall back to medium if no small version is returned.
            for img in imageList {
                if let h = img.mapValue("height")?.intValue, h >= 200 && h <= 400 {
                    return img.mapValue("url")?.stringValue ?? ""
                }
            }
            return imageList.first?.mapValue("url")?.stringValue ?? ""
        }()
        // Keep the remote https URL — the firmware unconditionally prepends
        // `https://` to any image_url that doesn't start with `http`, which
        // turns a `data:image/...` URL into a broken `https://data:image/...`.
        // Inlining the image bytes doesn't work via the cluster path; the
        // firmware always fetches via `spotify.image.fetch` from this URL.
        let imageURL = remoteImageURL
        let trackURI = item?.mapValue("uri")?.stringValue ?? ""
        let durationMs = item?.mapValue("duration_ms")?.intValue ?? 0
        let progressMs = rest.mapValue("progress_ms")?.intValue ?? 0
        let isPlaying = rest.mapValue("is_playing")?.boolValue ?? false
        let deviceId = rest.mapValue("device")?.mapValue("id")?.stringValue ?? ""
        let contextUri = rest.mapValue("context")?.mapValue("uri")?.stringValue ?? ""
        let shuffle = rest.mapValue("shuffle_state")?.boolValue ?? false
        let repeatState = rest.mapValue("repeat_state")?.stringValue ?? "off"

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let timestampStr = "\(nowMs)"

        let metadata: MessagePackValue = .map([
            (.string("title"), .string(title)),
            (.string("artist_name"), .string(artistName)),
            (.string("album_title"), .string(albumTitle)),
            (.string("image_url"), .string(imageURL)),
            (.string("duration"), .int(Int64(durationMs)))
        ])

        let track: MessagePackValue = .map([
            (.string("uri"), .string(trackURI)),
            (.string("metadata"), metadata)
        ])

        let options: MessagePackValue = .map([
            (.string("shuffling_context"), .bool(shuffle)),
            (.string("repeating_context"), .bool(repeatState == "context")),
            (.string("repeating_track"), .bool(repeatState == "track"))
        ])

        let playerState: MessagePackValue = .map([
            (.string("track"), track),
            (.string("playback_id"), .string(UUID().uuidString.lowercased())),
            (.string("is_playing"), .bool(isPlaying)),
            (.string("is_paused"), .bool(!isPlaying)),
            (.string("is_buffering"), .bool(false)),
            (.string("position_as_of_timestamp"), .string("\(progressMs)")),
            (.string("duration"), .int(Int64(durationMs))),
            (.string("timestamp"), .string(timestampStr)),
            (.string("context_uri"), .string(contextUri)),
            (.string("options"), options)
        ])

        // `cluster.devices` MUST be populated for the firmware to render
        // anything. Its `useSpotifyPlayerState` hook reads
        // `cluster.devices[activeDeviceId].device_type` before transforming
        // the player_state — if it's missing or empty, it short-circuits
        // and the UI stays blank. We synthesize the active device entry
        // from /me/player's `device` block.
        let device = rest.mapValue("device")
        let deviceName = device?.mapValue("name")?.stringValue ?? "Mac"
        let deviceType = device?.mapValue("type")?.stringValue ?? "Computer"
        let deviceVolumeRaw = device?.mapValue("volume_percent")?.intValue ?? 50
        let supportsVolume = device?.mapValue("supports_volume")?.boolValue ?? true
        // Spotify Connect dealer reports `volume` as 0-65535. The REST API
        // reports `volume_percent` as 0-100. Convert.
        let volume16 = max(0, min(65535, deviceVolumeRaw * 65535 / 100))

        let activeDeviceEntry: MessagePackValue = .map([
            (.string("device_id"), .string(deviceId)),
            (.string("name"), .string(deviceName)),
            (.string("device_type"), .string(deviceType)),
            (.string("is_active"), .bool(true)),
            (.string("is_private_session"), .bool(false)),
            (.string("is_restricted"), .bool(false)),
            (.string("supports_volume"), .bool(supportsVolume)),
            (.string("volume"), .int(Int64(volume16))),
            (.string("volume_steps"), .int(0))
        ])

        let devicesMap: MessagePackValue
        if deviceId.isEmpty {
            devicesMap = .map([])
        } else {
            devicesMap = .map([(.string(deviceId), activeDeviceEntry)])
        }

        let cluster: MessagePackValue = .map([
            (.string("player_state"), playerState),
            (.string("active_device_id"), .string(deviceId)),
            (.string("devices"), devicesMap),
            (.string("timestamp"), .string(timestampStr))
        ])

        // Note: `update_reason` is deliberately omitted from the payload
        // entry. The Pi connector's `cleanupWebSocketMessage` deletes it
        // before forwarding — the reason is encoded in the topic name
        // instead (we set that in broadcastSpotifyState).
        let payloadEntry: MessagePackValue = .map([
            (.string("cluster"), cluster)
        ])

        return .map([
            (.string("payloads"), .array([payloadEntry])),
            (.string("phone_timestamp_ms"), .int(nowMs))
        ])
    }

    /// Builds the Spotify-cluster-shaped event payload the Car Thing UI expects.
    /// Mirrors what `cleanupWebSocketMessage` returns in src/server/services/spotify-filters.ts.
    private func buildSpotifyClusterEvent(snap: NowPlayingState, reason: String) -> MessagePackValue {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let timestampStr = "\(nowMs)"
        let trackName = snap.trackName ?? ""
        let artistName = snap.artistName ?? ""
        let albumName = snap.albumName ?? ""
        let imageUrl = snap.albumArtURL?.absoluteString ?? ""
        let durationMs = snap.durationMs ?? 0
        let progressMs = snap.progressMs ?? 0
        let isPlaying = snap.isPlaying
        let trackUri = "spotify:local:\(percentEncode(artistName)):\(percentEncode(albumName)):\(percentEncode(trackName)):\(durationMs / 1000)"

        let metadata: MessagePackValue = .map([
            (.string("title"), .string(trackName)),
            (.string("artist_name"), .string(artistName)),
            (.string("album_title"), .string(albumName)),
            (.string("image_url"), .string(imageUrl)),
            (.string("duration"), .int(Int64(durationMs)))
        ])

        let track: MessagePackValue = .map([
            (.string("uri"), .string(trackUri)),
            (.string("metadata"), metadata)
        ])

        let playerState: MessagePackValue = .map([
            (.string("track"), track),
            (.string("playback_id"), .string(UUID().uuidString.lowercased())),
            (.string("is_playing"), .bool(isPlaying)),
            (.string("is_paused"), .bool(!isPlaying)),
            (.string("is_buffering"), .bool(false)),
            (.string("position_as_of_timestamp"), .string("\(progressMs)")),
            (.string("duration"), .int(Int64(durationMs))),
            (.string("timestamp"), .string(timestampStr))
        ])

        // Synthesize a single active-device entry so the firmware's
        // `cluster.devices[activeDeviceId].device_type` lookup succeeds.
        // Without this the UI stays blank.
        let macDevice: MessagePackValue = .map([
            (.string("device_id"), .string("mac-local")),
            (.string("name"), .string("Mac")),
            (.string("device_type"), .string("Computer")),
            (.string("is_active"), .bool(true)),
            (.string("is_private_session"), .bool(false)),
            (.string("is_restricted"), .bool(false)),
            (.string("supports_volume"), .bool(true)),
            (.string("volume"), .int(32768)),
            (.string("volume_steps"), .int(0))
        ])

        let cluster: MessagePackValue = .map([
            (.string("player_state"), playerState),
            (.string("active_device_id"), .string("mac-local")),
            (.string("devices"), .map([(.string("mac-local"), macDevice)])),
            (.string("timestamp"), .string(timestampStr))
        ])

        let payloadEntry: MessagePackValue = .map([
            (.string("cluster"), cluster)
        ])

        return .map([
            (.string("payloads"), .array([payloadEntry])),
            (.string("phone_timestamp_ms"), .int(nowMs))
        ])
    }

    private func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - Helpers

    private func parseDeviceInfo(_ value: MessagePackValue) -> CarThingInfo {
        CarThingInfo(
            device: value.mapValue("device")?.stringValue,
            version: value.mapValue("version")?.stringValue,
            fullVersion: value.mapValue("fullVersion")?.stringValue,
            buildDate: value.mapValue("buildDate")?.stringValue,
            gitHash: value.mapValue("gitHash")?.stringValue,
            serialNumber: value.mapValue("serialNumber")?.stringValue
        )
    }

    private func currentTimeMap() -> [(MessagePackValue, MessagePackValue)] {
        let now = Date()
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let pad: (Int) -> String = { String(format: "%02d", $0) }
        let datetime = "\(cal.component(.year, from: now))-\(pad(cal.component(.month, from: now)))-\(pad(cal.component(.day, from: now))) \(pad(cal.component(.hour, from: now))):\(pad(cal.component(.minute, from: now))):\(pad(cal.component(.second, from: now)))"
        let local = Calendar.current
        let time = "\(pad(local.component(.hour, from: now))):\(pad(local.component(.minute, from: now))):\(pad(local.component(.second, from: now)))"
        return [
            (.string("datetime"), .string(datetime)),
            (.string("time"), .string(time))
        ]
    }

    private func currentTimezoneMap() -> [(MessagePackValue, MessagePackValue)] {
        let tz = TimeZone.current
        let now = Date()
        return [
            (.string("identifier"), .string(tz.identifier)),
            (.string("secondsFromGMT"), .int(Int64(tz.secondsFromGMT(for: now)))),
            (.string("abbreviation"), .string(tz.abbreviation(for: now) ?? "")),
            (.string("isDaylightSavingTime"), .bool(tz.isDaylightSavingTime(for: now)))
        ]
    }

    /// Called immediately after handling a transport RPC. Forces the local
    /// `nowPlaying.state.isPlaying` to match the user's *intent* (rather than
    /// whatever stale snapshot MediaRemote might still be pushing), then
    /// fires a forced broadcast so the Car Thing's UI flips its play/pause
    /// icon without waiting for the next polling tick. Also fires a second
    /// broadcast ~250ms later so any catch-up state from MediaRemote lands too.
    private func pushFreshStateAfterTransport(isPlayingHint: Bool) async {
        nowPlaying.overrideIsPlaying(isPlayingHint)
        // Drop the cached /me/player so the next fetch sees the post-transport
        // state. Without this, we'd send the Car Thing a stale snapshot that
        // still shows the previous play/pause/track state for up to 2s.
        invalidatePlayerStateCache()
        await broadcastSpotifyState(reason: "PLAYER_STATE_CHANGED", force: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.invalidatePlayerStateCache()
            await self?.broadcastSpotifyState(reason: "PLAYER_STATE_CHANGED", force: true)
        }
    }

    // MARK: - Spotify Web API proxy
    //
    // When the user has completed the Spotify device-authorization flow in
    // the setup wizard, we route the Car Thing's transport calls through
    // `api.spotify.com` directly. That bypasses macOS's Automation prompt
    // entirely and works for play/pause (which the firmware otherwise tries
    // to send via Spotify Connect WebSocket, requiring full Web auth on the
    // Car Thing side too).

    /// Returns true if we successfully issued the Web API request (regardless
    /// of HTTP success). Returns false only if there's no linked Spotify
    /// account, so the caller can fall through to the local bridge.
    @discardableResult
    private func spotifyWebTransport(path: String, method: String) async -> Bool {
        guard var creds = SessionStore.shared.loadSpotifyCredentials() else {
            log.info("Spotify Web token absent; skipping web-api \(path, privacy: .public)")
            return false
        }
        // Honor the global cooldown — without this, transport calls fire
        // during a /me/player 429 and just stack more 429s, each one
        // extending Spotify's penalty timer.
        if Date() < webAPICooldownUntil {
            log.info("spotify-web \(method, privacy: .public) /\(path, privacy: .public) skipped (in cooldown)")
            // Return false so the caller falls back to the local bridge
            // (MediaController / AppleScript) for at least *some* response.
            return false
        }
        if creds.expiresAt < Date().addingTimeInterval(60) {
            await spotify.bootstrap()
            if let refreshed = SessionStore.shared.loadSpotifyCredentials() {
                creds = refreshed
            }
        }
        let url = URL(string: "https://api.spotify.com/v1/me/player/\(path)")!
        do {
            let (data, http) = try await api.request(
                url, method: method,
                headers: ["Authorization": "Bearer \(creds.accessToken)"]
            )
            log.info("spotify-web \(method, privacy: .public) /\(path, privacy: .public) -> \(http.statusCode, privacy: .public)")
            if http.statusCode == 429 {
                // Update the cooldown — the missing piece that let transport
                // calls keep eating 429s and escalating Spotify's penalty.
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) ?? 30
                webAPICooldownUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("spotify-web 429 \(method, privacy: .public) /\(path, privacy: .public) retryAfter=\(retryAfter, privacy: .public)s body=\(body, privacy: .public)")
                return false  // Let the local bridge cover the gap.
            }
            if http.statusCode == 401 {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("spotify-web 401 \(method, privacy: .public) /\(path, privacy: .public) — token rejected. body=\(body, privacy: .public)")
                await spotify.bootstrap()
                return false
            }
            if http.statusCode == 404 {
                let body = String(data: data, encoding: .utf8) ?? ""
                log.warning("No active Spotify device — play/pause may need playback started on a device first. body=\(body, privacy: .public)")
            }
            return true
        } catch {
            log.warning("spotify-web /\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return true  // We tried — don't double-dispatch to the local bridge.
        }
    }

    @discardableResult
    private func spotifyWebVolume(percent: Int) async -> Bool {
        guard let creds = SessionStore.shared.loadSpotifyCredentials() else {
            return false
        }
        if Date() < webAPICooldownUntil {
            log.info("Volume Web API call skipped (in cooldown)")
            nowPlaying.setVolume(percent: percent)
            return true
        }
        var comp = URLComponents(string: "https://api.spotify.com/v1/me/player/volume")!
        comp.queryItems = [URLQueryItem(name: "volume_percent", value: "\(percent)")]
        do {
            let (_, http) = try await api.request(
                comp.url!, method: "PUT",
                headers: ["Authorization": "Bearer \(creds.accessToken)"]
            )
            log.info("spotify-web volume(\(percent, privacy: .public)) -> \(http.statusCode, privacy: .public)")
            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) ?? 30
                webAPICooldownUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                log.warning("Spotify Web rate-limited — cooling down for \(retryAfter, privacy: .public)s")
                nowPlaying.setVolume(percent: percent)
            }
            return true
        } catch {
            log.warning("spotify-web volume failed: \(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    /// Global rate-limit cooldown. When ANY Web API call returns 429, we
    /// suppress further Web API calls until this Date passes — keeps us from
    /// burning through Spotify's per-account quota.
    private var webAPICooldownUntil: Date = .distantPast

    /// Per-path cache for library-style Spotify Web API responses. The Car
    /// Thing's home screen calls 6+ endpoints in a burst on connect, which
    /// reliably trips Spotify's rate limiter. Caching aggressively (30s) and
    /// serving stale-during-cooldown means the burst hits the network once
    /// per path, then re-uses the cached payload for the rest of the session.
    private var proxyGetCache: [String: (payload: MessagePackValue, fetchedAt: Date)] = [:]
    private let proxyGetCacheTTL: TimeInterval = 30.0

    /// GET a Spotify Web API path with the linked access token, return the
    /// JSON response as a MessagePackValue. Cached for 30s per-path; during a
    /// 429 cooldown we keep serving the cached value instead of returning
    /// nil so the Car Thing's UI doesn't blank out.
    private func proxyWebGet(path: String) async -> (result: MessagePackValue?, error: String?) {
        // 1. Fresh cache hit — no network at all.
        if let cached = proxyGetCache[path],
           Date().timeIntervalSince(cached.fetchedAt) < proxyGetCacheTTL {
            return (cached.payload, nil)
        }
        // 2. In cooldown — serve stale rather than nothing.
        if Date() < webAPICooldownUntil {
            if let cached = proxyGetCache[path] {
                log.info("spotify-web GET \(path, privacy: .public) cooldown → serving cached")
                return (cached.payload, nil)
            }
            log.info("spotify-web GET \(path, privacy: .public) skipped (in cooldown, no cache)")
            return (.nilValue, nil)
        }
        // 3. No token — bail; can't reach Spotify.
        guard let creds = SessionStore.shared.loadSpotifyCredentials() else {
            return (proxyGetCache[path]?.payload ?? .nilValue, nil)
        }
        // 4. Fresh fetch.
        let url = URL(string: "https://api.spotify.com/v1/\(path)")!
        do {
            let (data, http) = try await api.request(
                url, method: "GET",
                headers: ["Authorization": "Bearer \(creds.accessToken)"]
            )
            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) ?? 30
                webAPICooldownUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("spotify-web 429 GET \(path, privacy: .public) retryAfter=\(retryAfter, privacy: .public)s body=\(body, privacy: .public)")
                // Serve cached payload while we wait, if we have one.
                if let cached = proxyGetCache[path] {
                    return (cached.payload, nil)
                }
                return (.nilValue, nil)
            }
            if http.statusCode == 401 {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("spotify-web 401 GET \(path, privacy: .public) — token rejected. body=\(body, privacy: .public)")
                await spotify.bootstrap()
                if let cached = proxyGetCache[path] { return (cached.payload, nil) }
                return (.nilValue, nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                log.warning("spotify-web HTTP \(http.statusCode, privacy: .public) GET \(path, privacy: .public) body=\(body, privacy: .public)")
                // Non-2xx; if we have stale data prefer it over erroring out.
                if let cached = proxyGetCache[path] {
                    return (cached.payload, nil)
                }
                return (.nilValue, "HTTP \(http.statusCode)")
            }
            let json = try JSONSerialization.jsonObject(with: data)
            let value = MessagePackValue.wrap(json)
            proxyGetCache[path] = (value, Date())
            return (value, nil)
        } catch {
            if let cached = proxyGetCache[path] {
                return (cached.payload, nil)
            }
            return (.nilValue, error.localizedDescription)
        }
    }

    /// Coalesce rapid volume RPCs from the Car Thing's wheel. Only the latest
    /// value within a 250ms quiet window is sent to Spotify, which keeps us
    /// well under their `~10 req/s` rate limit.
    private func queueVolumeChange(_ percent: Int) {
        pendingVolumeTarget = percent
        volumeDebounceTask?.cancel()
        volumeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, let target = self.pendingVolumeTarget else { return }
            self.pendingVolumeTarget = nil
            self.log.info("Volume → \(target, privacy: .public)%")
            if !(await self.spotifyWebVolume(percent: target)) {
                self.nowPlaying.setVolume(percent: target)
            }
        }
    }

    /// Parse a possibly-stringly-typed bool param.
    private func parseBool(_ v: MessagePackValue?) -> Bool? {
        guard let v else { return nil }
        switch v {
        case .bool(let b): return b
        case .string(let s):
            let lower = s.lowercased()
            if lower == "true" || lower == "on" || lower == "1" { return true }
            if lower == "false" || lower == "off" || lower == "0" { return false }
            return nil
        case .int(let i): return i != 0
        case .uint(let u): return u != 0
        default: return nil
        }
    }

    private func describe(_ value: MessagePackValue) -> String {
        switch value {
        case .nilValue:        return "nil"
        case .bool(let b):     return b ? "true" : "false"
        case .int(let i):      return "\(i)"
        case .uint(let u):     return "\(u)"
        case .double(let d):   return "\(d)"
        case .string(let s):   return "\"\(s)\""
        case .data(let d):     return "data(\(d.count)B)"
        case .array(let arr):
            return "[" + arr.map { describe($0) }.joined(separator: ", ") + "]"
        case .map(let entries):
            let inner = entries.map { (k, v) -> String in
                let key = k.stringValue ?? describe(k)
                return "\(key): \(describe(v))"
            }.joined(separator: ", ")
            return "{" + inner + "}"
        }
    }
}
