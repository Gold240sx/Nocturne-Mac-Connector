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
        stateObservation = nowPlaying.$state
            .removeDuplicates { a, b in
                a.trackName == b.trackName &&
                a.artistName == b.artistName &&
                a.isPlaying == b.isPlaying
            }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
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
            data.withUnsafeBytes { buf in
                let ptr = UnsafeMutableRawPointer(mutating: buf.baseAddress!)
                _ = channel.writeSync(ptr, length: UInt16(data.count))
            }
        }

        connections[key] = Connection(address: address, channel: channel, client: client)
        log.info("RPC client attached: \(key, privacy: .public)")

        startKeepAliveIfNeeded()
        startStateBroadcastIfNeeded()

        // Mirror the Pi's initial ping + device.info handshake, then announce app.ready.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.runInitialHandshake(key: key)
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

        // --- Spotify player surface (bridged to local Spotify.app via AppleScript) ---
        case "spotify.player.state":
            return (spotifyPlayerState(), nil)
        case "spotify.player.play", "spotify.player.resume":
            await nowPlaying.play()
            await pushFreshStateAfterTransport(isPlayingHint: true)
            return (.bool(true), nil)
        case "spotify.player.pause":
            await nowPlaying.pause()
            await pushFreshStateAfterTransport(isPlayingHint: false)
            return (.bool(true), nil)
        case "spotify.player.toggle", "spotify.player.playPause", "spotify.player.togglePlayPause":
            let wasPlaying = nowPlaying.state.isPlaying
            await nowPlaying.togglePlayPause()
            await pushFreshStateAfterTransport(isPlayingHint: !wasPlaying)
            return (.bool(true), nil)
        case "spotify.player.next", "spotify.player.skipNext":
            await nowPlaying.next()
            await pushFreshStateAfterTransport(isPlayingHint: true)
            return (.bool(true), nil)
        case "spotify.player.previous", "spotify.player.skipPrevious":
            await nowPlaying.previous()
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
            return (.map([
                (.string("displayName"), .string("Mac")),
                (.string("uri"), .string("spotify:user:mac")),
                (.string("country"), .string("US"))
            ]), nil)
        case "spotify.library.songs",
             "spotify.library.albums",
             "spotify.library.artists",
             "spotify.library.playlists":
            // Empty list — Car Thing renders an empty section instead of errors.
            return (.array([]), nil)

        // --- Image fetch: Car Thing asks us to download album art for it ---
        case "spotify.image.fetch":
            guard let urlStr = params.mapValue("url")?.stringValue,
                  let url = URL(string: urlStr) else {
                return (.nilValue, "missing or invalid 'url' param")
            }
            do {
                let (data, http) = try await api.request(url, method: "GET")
                guard (200..<300).contains(http.statusCode) else {
                    return (.nilValue, "image fetch HTTP \(http.statusCode)")
                }
                return (.map([
                    (.string("url"), .string(urlStr)),
                    (.string("data"), .data(data)),
                    (.string("contentType"), .string(http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"))
                ]), nil)
            } catch {
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

    // MARK: - Initial handshake (mirrors NocturneManager.sendInitialPing)

    private func runInitialHandshake(key: String) async {
        guard let conn = connections[key] else { return }
        do {
            _ = try await conn.client.call(method: "ping",
                                           params: .map([(.string("message"), .string("Mac connected"))]),
                                           timeout: 10)
            let info = try await conn.client.call(method: "device.info", params: .map([]), timeout: 10)
            log.info("device.info ← \(self.describe(info), privacy: .public)")
            deviceInfo = parseDeviceInfo(info)
            lastPing = Date()
            await broadcastAppReady()
        } catch {
            log.warning("Initial handshake failed: \(error.localizedDescription, privacy: .public)")
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
                for (_, conn) in self.connections {
                    do {
                        _ = try await conn.client.call(
                            method: "ping",
                            params: .map([
                                (.string("message"), .string("keepalive")),
                                (.string("volumePercent"), .int(50))
                            ]),
                            timeout: 10
                        )
                        self.lastPing = Date()
                    } catch {
                        self.log.warning("Keep-alive failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
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

        // Same payload, multiple topic names — different firmware versions
        // subscribe to different ones.
        let topics = ["spotify.player.state_changed", "spotify.player.update", "spotify.message"]
        for (_, conn) in connections {
            for topic in topics {
                await conn.client.sendEvent(topic: topic, data: payload)
            }
        }
        log.info("Broadcast player state to \(self.connections.count, privacy: .public) device(s): track=\(trackKey, privacy: .public) playing=\(isPlaying, privacy: .public)")
    }

    /// Fetch the live `/v1/me/player` payload from Spotify and wrap it in the
    /// Pi connector's `cleanupWebSocketMessage`-style envelope. Returns nil if
    /// the user hasn't linked Spotify or the request fails — callers should
    /// fall back to the synthesized shape.
    private func fetchSpotifyWebPlayerState() async -> MessagePackValue? {
        guard let creds = SessionStore.shared.loadSpotifyCredentials() else { return nil }
        if Date() < webAPICooldownUntil { return nil }
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
                log.warning("Web player-state 429 — cooling down for \(retryAfter, privacy: .public)s")
                return nil
            }
            guard (200..<300).contains(http.statusCode) else { return nil }
            // Decode the JSON, then re-encode into MessagePackValue verbatim so
            // any field the firmware reads is preserved.
            let json = try JSONSerialization.jsonObject(with: data)
            let player = MessagePackValue.wrap(json)
            // Wrap in the Pi's cluster envelope shape: { payloads: [{ cluster:
            // { player_state: <player>, ... }}], phone_timestamp_ms }.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            return .map([
                (.string("payloads"), .array([
                    .map([(.string("cluster"), .map([
                        (.string("player_state"), player),
                        (.string("active_device_id"), .string(player.mapValue("device")?.mapValue("id")?.stringValue ?? "")),
                        (.string("timestamp"), .string("\(nowMs)"))
                    ]))])
                ])),
                (.string("phone_timestamp_ms"), .int(nowMs))
            ])
        } catch {
            return nil
        }
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

        let cluster: MessagePackValue = .map([
            (.string("player_state"), playerState),
            (.string("active_device_id"), .string("mac-local")),
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
        await broadcastSpotifyState(reason: "PLAYER_STATE_CHANGED", force: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
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
        if creds.expiresAt < Date().addingTimeInterval(60) {
            // Force a refresh by bouncing through SpotifyService; bootstrap()
            // pulls a fresh access token via the refresh-token flow.
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

    /// GET a Spotify Web API path with the linked access token, return the
    /// JSON response as a MessagePackValue. Respects the 429 cooldown.
    private func proxyWebGet(path: String) async -> (result: MessagePackValue?, error: String?) {
        if Date() < webAPICooldownUntil {
            log.info("spotify-web GET \(path, privacy: .public) skipped (in cooldown)")
            return (.nilValue, nil)
        }
        guard let creds = SessionStore.shared.loadSpotifyCredentials() else {
            return (.nilValue, nil)
        }
        let url = URL(string: "https://api.spotify.com/v1/\(path)")!
        do {
            let (data, http) = try await api.request(
                url, method: "GET",
                headers: ["Authorization": "Bearer \(creds.accessToken)"]
            )
            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) ?? 30
                webAPICooldownUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                log.warning("spotify-web 429 — cooling down for \(retryAfter, privacy: .public)s")
                return (.nilValue, nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                return (.nilValue, "HTTP \(http.statusCode)")
            }
            let json = try JSONSerialization.jsonObject(with: data)
            return (MessagePackValue.wrap(json), nil)
        } catch {
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
