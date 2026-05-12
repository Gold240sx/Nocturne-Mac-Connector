# Non-Spotify Sources via MediaRemoteAdapter

## Why this exists

The Mac connector is wired through two media sources:

1. **Spotify Web API** (`/v1/me/player`) — authoritative for transport
   (play/pause/skip/volume) and for the rich cluster shape the Car Thing
   firmware was built to consume.
2. **`MediaRemoteAdapter`** (Perl-bridged `MRMediaRemoteGetNowPlayingInfo`)
   — system-wide "what's playing on this Mac" feed. Works for **any** app
   that registers with macOS's NowPlaying framework: Apple Music, Music,
   Podcasts, Safari/Chrome video, VLC, even browser-based players.

Today, only the Spotify path produces a cluster the Car Thing renders.
When the user is playing something else (Apple Music, a YouTube video,
etc.), `MediaRemoteAdapter` reports the metadata but we don't forward it
to the Car Thing — the user gets a stale display or nothing.

This doc captures everything we'd need to extend coverage to non-Spotify
sources, knowing what we now know about the firmware's expectations
(see `album-art.md` for the painful path we took to learn those).

## The MediaRemote payload

`Services/MediaRemoteService.swift::handle(trackInfo:)` consumes
`TrackInfo.Payload` from the `ejbills/mediaremote-adapter` package. The
fields we care about:

| MediaRemote field         | Type    | Notes                                  |
|---------------------------|---------|----------------------------------------|
| `title`                   | String  | Track name                             |
| `artist`                  | String  | Artist name (singular — no array)      |
| `album`                   | String  | Album title                            |
| `applicationName`         | String  | "Music", "Safari", "Spotify", etc.     |
| `bundleIdentifier`        | String  | e.g. `com.apple.Music`                 |
| `isPlaying`               | Bool    |                                        |
| `durationMicros`          | Int64   | μs (we convert to ms for the cluster)  |
| `currentElapsedTime`      | Double  | seconds (convert to ms)                |
| `artworkDataBase64`       | String? | Inline image bytes, already base64'd   |
| `artworkMimeType`         | String? | `image/jpeg` / `image/png` typically   |

What it **doesn't** have:

- Multiple artist objects (just one string — even for collaborations the
  Apple framework concatenates with `feat.`/`&`)
- A track URI / album URI (just human-readable strings)
- Context (no playlist/album URI to navigate to)
- Multiple image sizes (just whichever resolution the source app handed
  the system, often 600×600-ish)

## Mapping to the firmware's cluster shape

The Car Thing's `useSpotifyPlayerState` (firmware) reads `playerState`
from `payloads[0].cluster.player_state`. The fields it indexes:

```
cluster.active_device_id                            ← required
cluster.devices[active_device_id]                   ← required (any shape with device_type)
cluster.player_state.track.uri                      ← needed for item.id derivation
cluster.player_state.track.metadata.title           ← display
cluster.player_state.track.metadata.artist_name     ← legacy singular fallback
cluster.player_state.track.metadata.artists         ← array of {id, uri, name, type}
cluster.player_state.track.metadata.album_title     ← display
cluster.player_state.track.metadata.album_uri       ← navigation
cluster.player_state.track.metadata.image_url       ← MUST start with "http" or
                                                       firmware prepends "https://"
cluster.player_state.track.metadata.duration        ← ms (string-ified in cluster)
cluster.player_state.is_playing                     ← bool
cluster.player_state.is_paused                      ← bool (firmware reads this primarily)
cluster.player_state.position_as_of_timestamp      ← ms, STRINGIFIED
cluster.player_state.duration                       ← ms
cluster.player_state.timestamp                      ← unix ms, stringified
cluster.player_state.context_uri                    ← spotify:playlist:... or empty
cluster.player_state.options.{shuffling_context, repeating_context, repeating_track}
```

The adapter from MediaRemote → cluster:

```
MediaRemote.title              → metadata.title
MediaRemote.artist             → metadata.artist_name
                                 metadata.artists = [{
                                   id: "local-<hash>",
                                   uri: "local:artist:<urlencoded-name>",
                                   name: <artist>,
                                   type: "artist"
                                 }]
MediaRemote.album              → metadata.album_title
                                 metadata.album_uri = "local:album:<urlencoded-name>"
MediaRemote.durationMicros/1000 → metadata.duration AND player_state.duration
MediaRemote.currentElapsedTime*1000 → player_state.position_as_of_timestamp (stringified)
MediaRemote.isPlaying          → is_playing  /  is_paused (inverted)
MediaRemote.artworkDataBase64  → see "The artwork problem" below
MediaRemote.applicationName    → cluster.devices[active_device_id].name
MediaRemote.bundleIdentifier   → cluster.active_device_id (sanitize for cluster key)
                                 cluster.devices[ID].device_type = "Computer"
no equivalent                  → context_uri (leave empty, or synthesize "local:context:app")
no equivalent                  → track.uri (synthesize "local:track:<urlencoded-title>")
```

### The artwork problem

MediaRemote hands us **inline bytes already base64-encoded**. We have no
URL — the source app generated the artwork itself and there's no CDN
behind it.

The firmware's image flow expects an HTTPS URL it can pass back via
`spotify.image.fetch`. We can't return random https URLs.

Two viable approaches:

**A. Synthetic URL with handler interception.** Make up a URL like
`https://local.media/<bundle-id>/<hash>` and put it in
`metadata.image_url`. In our `spotify.image.fetch` handler, detect URLs
matching `local.media/` and return the cached MediaRemote bytes
(already base64) instead of doing an HTTPS download. Requires a per-app
in-memory cache keyed by the bundle ID + track URI hash.

```swift
// In RPCManager:
private var localArtworkCache: [String: (data: String, mime: String)] = [:]

// MediaRemote → handle(trackInfo:) → store in cache:
if let b64 = info.artworkDataBase64, let title = info.title {
    let key = "\(info.bundleIdentifier ?? "?"):\(title)"
    localArtworkCache[key] = (b64, info.artworkMimeType ?? "image/jpeg")
}

// Build a "URL" the firmware will pass back to us:
let synthURL = "https://local.media/\(key.urlEncoded)"

// In spotify.image.fetch handler:
if urlStr.hasPrefix("https://local.media/") {
    let key = String(urlStr.dropFirst("https://local.media/".count)).urlDecoded
    if let cached = localArtworkCache[key] {
        return (.map([
            (.string("data"), .string(cached.data)),
            (.string("contentType"), .string(cached.mime)),
            (.string("size"), .int(Int64(cached.data.count * 3 / 4)))
        ]), nil)
    }
}
```

The firmware can't tell the difference between this synthetic URL and a
real Spotify CDN URL — the handler is just an opaque "give me bytes for
URL X" call.

**B. Resize the bytes to ~64×64 ourselves before serving.** MediaRemote
artwork is usually 600×600 or so. Per `album-art.md`, the WebView's color
extraction hangs on anything larger than ~7KB base64. So whatever path
we take, we'd need to downscale before serving:

```swift
import AppKit
extension Data {
    func downscaledJPEG(maxDimension: CGFloat = 64, quality: CGFloat = 0.8) -> Data? {
        guard let img = NSImage(data: self) else { return nil }
        let aspect = img.size.height / max(img.size.width, 1)
        let w = min(maxDimension, img.size.width)
        let h = w * aspect
        let target = NSImage(size: NSSize(width: w, height: h))
        target.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: target.size))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
```

Combine A and B: synthetic URL keyed by track, handler returns
downscaled bytes from cache.

## Sketch of the integration

```
┌────────────────────────────────────────────────────────────────────┐
│ Source selection                                                   │
├────────────────────────────────────────────────────────────────────┤
│ Spotify Web API linked & active device exists?                     │
│     YES → use Spotify path (today's behavior)                      │
│     NO  → fall back to MediaRemoteService.state                    │
│           build cluster from NowPlayingState                       │
│           use synthetic local.media/ URL for artwork               │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│ Cluster build (new path, parallel to buildClusterFromRESTPlayer)   │
├────────────────────────────────────────────────────────────────────┤
│ buildClusterFromMediaRemote(snap: NowPlayingState) -> MessagePack  │
│   - synthesize track.uri = "local:track:<hash>"                    │
│   - synthesize artists = [{id, uri, name, type:"artist"}]          │
│   - metadata.image_url = "https://local.media/<key>"               │
│   - same envelope as Spotify cluster (cluster.devices required)    │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│ Transport routing                                                  │
├────────────────────────────────────────────────────────────────────┤
│ spotify.player.play/pause/next/previous/toggle                     │
│   - If Spotify token + active device → route to Web API            │
│   - Else route to local MediaController (already implemented in    │
│     NowPlayingService.play/pause/next/previous)                    │
│ spotify.player.volume                                              │
│   - Web API when linked, AppleScript fallback otherwise            │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│ Artwork fetch (handler intercept)                                  │
├────────────────────────────────────────────────────────────────────┤
│ spotify.image.fetch URL:                                           │
│   - https://i.scdn.co/...  → existing Spotify CDN download         │
│   - https://local.media/<key> → return localArtworkCache[key]      │
└────────────────────────────────────────────────────────────────────┘
```

## Open design questions

- **Source switching mid-session.** If the user starts in Spotify then
  switches to Apple Music, we need to (a) notice, (b) rebuild the
  cluster from MediaRemote, (c) re-broadcast with the new image_url so
  the Car Thing re-fetches. Detection signal: when `/me/player` returns
  HTTP 204 *and* MediaRemote reports playing=true, the source has shifted.
  Add a `preferredSource: enum { .spotifyWeb, .localMedia }` selector
  derived from those two states.
- **Transport from Car Thing for non-Spotify.** The firmware sends
  `spotify.player.play/pause/...` regardless of source. For Apple Music,
  these need to route to the local AppleScript bridge (already in
  `SpotifyAppleScriptReader` — but currently hardcoded to "Spotify"
  application). Generalize to dispatch by `info.applicationName`.
- **Volume.** No Web API equivalent for non-Spotify apps. AppleScript
  volume control is per-app (`tell app "Music" to set sound volume to N`).
  Generalize the volume handler the same way as transport.
- **Library calls.** The Car Thing's home-screen RPCs
  (`spotify.me.recentlyPlayed`, `.playlists`, etc.) only make sense for
  Spotify. When the source is local media, these should return empty
  arrays so the home screen renders empty rows rather than infinite
  loading spinners.

## What we now know that informs the design

From the album-art work:

- The cluster topic must be `spotify.player.device_state_changed`. Other
  topics are silently ignored by the firmware.
- `cluster.devices[active_device_id]` is required — without it, the
  firmware's transform short-circuits before reading `player_state`.
- RPC reply envelope must use `type: "result"`. nocturned re-tags to
  `"response"` before forwarding to the WebView.
- Binary fields (`bin8/16/32`) get converted to JSON number arrays by
  `nocturned`'s `rmpv_to_json`. **Always send base64 strings** for image
  data — never msgpack binary.
- The firmware's WebView reliably renders 64×64 album art. 300×300 and
  640×640 hang the color-extraction canvas pass. Whatever artwork we
  serve from MediaRemote should be **downscaled before encoding** to
  stay under ~7KB base64.

## Files to extend (when this happens)

- `Services/MediaRemoteService.swift` — already extracts the fields we
  need. Add a `latestPayload` getter so RPCManager can read raw on demand
  instead of hooking onUpdate only.
- `Services/NowPlayingService.swift` — already has a `source` enum
  (`mediaRemote`, `spotifyApp`, `none`). Surface this to RPCManager so it
  can pick the cluster build path.
- `Services/RPCManager.swift` — add `buildClusterFromMediaRemote(_:)`
  paralleling `buildClusterFromRESTPlayer(_:)`. Wire selection in
  `fetchSpotifyWebPlayerState` (or a new method that combines).
- `Services/RPCManager.swift::spotify.image.fetch` handler — detect
  `https://local.media/` URLs and return from cache instead of HTTP
  fetching.

## Related project memories

- `reference_msgpack_to_json_bridge.md` — base64 string is the safe type
  for binary payloads
- `reference_rpc_response_type.md` — `type:"result"` over the wire
- `project_nocturne_ui_cluster.md` — cluster topic + devices map
- `album-art.md` — the 64×64 size constraint
