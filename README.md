<img src="https://utfs.io/f/3394da99-784c-4153-b71d-450d4e3e48b3-1xajxz.jpg" alt="Nocturne-Mac-Connector" width="650">

# Nocturne-Mac-Connector

Control your Spotify (and eventually any media playing on your Mac) from
the Spotify Car Thing — flashed with the [Nocturne firmware](https://github.com/usenocturne/nocturne).

This is a SwiftUI port of the iPhone/Android-only [nocturne-connector](https://github.com/usenocturne/nocturne-connector)
that uses Authorization Code + PKCE for Spotify OAuth and bridges
playback state, transport, and library calls to the Car Thing over
Bluetooth RFCOMM (msgpack-base64 framing).

## ⚠️ Bring Your Own Spotify Client ID

**If you fork this repo to build it for yourself, you have to register
your own Spotify app and paste its Client ID into
`Nocturne-Mac/Utilities/Configuration.swift`.** Don't ship with mine.

Why this matters:

- Spotify's API quotas are **per-app**, not per-user. A shared client ID
  burns out quickly under multiple developers' traffic and triggers
  `429 "API rate limit exceeded"` for everyone tied to it.
- New Spotify apps are in **Development Mode** — limited to 25 users on
  a whitelist that only the app owner can edit. Tokens issued to
  non-whitelisted users get 403s.
- The client ID is baked into the binary. You don't want your app
  depending on someone else's revocation decisions.

Full setup walkthrough (5 minutes): **[`docs/setup-spotify-client.md`](docs/setup-spotify-client.md)**

Quick version:

1. Register an app at <https://developer.spotify.com/dashboard>.
2. Redirect URI: `http://127.0.0.1:8888/callback`
3. APIs Used: **Web API only** (do NOT check iOS SDK or fill the Bundle ID
   field — those force a different OAuth grant that we don't use, and
   Spotify will refuse with `unauthorized_client`).
4. Settings → User Management → Add your Spotify email.
5. Paste the Client ID into `Configuration.swift::spotifyClientID`.
6. Build. Launch. Click "Link Spotify". Done.

## What works

- Now-playing track / artist(s) / album art on the Car Thing screen,
  updating as you skip
- Transport: play / pause / next / previous / volume / seek / shuffle / repeat
- Heart icon's filled state (read of saved status) — but see "What's
  missing" for the save/unsave gap
- Spotify Connect device list
- Home-screen rows: Liked Songs, Playlists, Top Artists / Tracks, Saved
  Albums, Shows, Recently Played, Search
- Auto-reconnect with cooldown when the Car Thing's nocturned daemon
  refuses an RFCOMM open
- macOS Automation permission auto-registration (the app appears under
  System Settings → Automation on first launch)

## What's missing / known limitations

- **Album art is 64×64 only** (up-scales to the 280×280 NowPlaying slot —
  softer than ideal but it's the only size that renders).
  300×300 and 640×640 silently hang the firmware's color-extraction
  canvas pass. Full investigation: [`docs/album-art.md`](docs/album-art.md).
- **Save/Unsave (heart button) doesn't persist.** UI flips optimistically
  on the Car Thing but the change doesn't reach Spotify. Implementation
  sketch: [`docs/library-and-source-signaling.md`](docs/library-and-source-signaling.md#1-like--dislike-saveunsave).
- **Library coverage is "home screen complete" but not exhaustive.**
  Artist detail, Browse / Categories, queue manipulation, playlist
  editing — all probably need handlers that haven't been written yet.
  How to discover the exact RPC names: same doc, section 2.
- **Non-Spotify sources (Apple Music, browser, etc.) not yet displayed.**
  We already read system NowPlaying via [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter)
  for the local UI, but don't yet forward to the Car Thing. Integration
  design: [`docs/non-spotify-sources.md`](docs/non-spotify-sources.md)
  and [`docs/library-and-source-signaling.md`](docs/library-and-source-signaling.md#3-player-source-signaling-for-the-dual-entry-path).

## Documentation

This repo includes pretty thorough notes on why things are the way they
are. The protocol details aren't documented anywhere else and took
real time to figure out — saving them so the next person doesn't
repeat the work.

| Doc | Covers |
|-----|--------|
| [`docs/setup-spotify-client.md`](docs/setup-spotify-client.md) | Step-by-step Spotify developer dashboard setup, why each setting matters, token rotation |
| [`docs/album-art.md`](docs/album-art.md) | Why album art is 64×64 only — every protocol gotcha we hit, color-extraction WebView bug, render cycle thrash, path forward |
| [`docs/non-spotify-sources.md`](docs/non-spotify-sources.md) | How to extend the cluster build to MediaRemoteAdapter so Apple Music / browser playback displays. Synthetic local.media/ URL trick for inline artwork. |
| [`docs/library-and-source-signaling.md`](docs/library-and-source-signaling.md) | The save/unsave gap, library RPC coverage map, three source-signaling options for dual-entry (`is_phone_media`, `media.nowPlaying.*` topics, `device_type`) |

## Architecture quick reference

- **`Services/SpotifyService.swift`** — Authorization Code + PKCE OAuth.
  Spawns a one-shot HTTP listener on `127.0.0.1:8888` via
  `LocalhostCallbackServer.swift` to catch the redirect.
- **`Services/BluetoothService.swift`** — IOBluetooth wrapper. Publishes
  an SPP SDP record on channel 1 for inbound RFCOMM, dials outbound to
  ch 2 for the RPC channel, manages connection state.
- **`Services/RPCManager.swift`** — the meat. Attaches an
  `RPCClient` per channel, dispatches Car Thing → Mac calls
  (`spotify.player.*`, `spotify.me.*`, etc.), broadcasts cluster updates
  back to the firmware, downloads album art on demand.
- **`Services/MediaRemoteService.swift`** — Perl-bridged
  `MRMediaRemoteGetNowPlayingInfo`. System-wide "what's playing" feed.
  Currently used for the Mac UI's now-playing card; the doc above
  sketches how to extend it to drive the Car Thing too.
- **`Services/NowPlayingService.swift`** — abstracts over MediaRemote
  and AppleScript fallbacks. Transport routes through here.
- **`RPC/{RPCClient,RPCProtocol,Chunking,MessagePack}.swift`** — the
  wire protocol. Base64-newline framed msgpack chunks with CRC32
  verification and reassembly by message ID. Mirrors the Pi connector's
  `src/server/rpc/`.
- **`Nocturne-Mac/Nocturne-Mac.entitlements`** — `com.apple.security.automation.apple-events`
  for AppleScript bridge. Without this entitlement, hardened runtime
  rejects all Apple Events silently and the app never appears under
  System Settings → Automation.

## Wishlist / nice-to-haves

- Status bar / hide from dock option
- Open-on-login toggle
- Apple Music / browser playback bridged to Car Thing (see
  `docs/non-spotify-sources.md`)
- Save/unsave actually persisting (~30 min of code, see
  `docs/library-and-source-signaling.md`)
- Sharper album art — requires a [firmware patch](docs/album-art.md#path-forward-firmware-only)

## Credits & related projects

- Nocturne Firmware: [usenocturne/nocturne](https://github.com/usenocturne/nocturne)
- Nocturne UI (the Car Thing-side React app): [usenocturne/nocturne-ui](https://github.com/usenocturne/nocturne-ui)
- Nocturne Connector (Pi/Bun reference impl): [usenocturne/nocturne-connector](https://github.com/usenocturne/nocturne-connector)
- nocturned (Rust daemon on the Car Thing): [usenocturne/nocturned](https://github.com/usenocturne/nocturned)
- MediaRemoteAdapter: [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter)
- Nocturne Website: <https://usenocturne.com>

If this is useful, consider donating to the Nocturne project — none of
this would exist without their firmware work.
