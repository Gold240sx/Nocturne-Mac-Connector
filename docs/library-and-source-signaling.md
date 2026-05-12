# Library Coverage, Source Signaling, and the Save/Unsave Gap

This doc captures the gaps in the connector's RPC surface that came up
during testing and what it would take to close each one. Companion to
`album-art.md` (which covers the now-playing image constraint) and
`non-spotify-sources.md` (which covers extending to Apple Music etc).

## 1. Like / Dislike (save/unsave)

### What works today

The Car Thing's player UI shows a **heart icon** next to the track. The
firmware drives its filled/empty state from `spotify.me.tracks.contains` —
"is this track ID in the user's library?" — which our handler proxies to
`GET /v1/me/tracks/contains?ids=<id>`. The icon renders correctly.

### What's missing

When the user *taps* the heart, the firmware sends an RPC we don't
handle, so the call falls through to our `Unhandled RPC method` default
and Spotify's library never actually changes. The user sees the heart
optimistically flip on the Car Thing screen but the change doesn't
persist — refresh and it's back where it started.

### The handlers to add

The firmware almost certainly calls one of these method names (the Pi
connector's `spotify-commands.ts` is the canonical reference for the
exact names — but based on Spotify's own conventions and the naming we've
seen on the read side, these are the right ones):

| RPC method | Spotify Web endpoint |
|------------|----------------------|
| `spotify.me.tracks.save` | `PUT /v1/me/tracks?ids=<id>` |
| `spotify.me.tracks.remove` | `DELETE /v1/me/tracks?ids=<id>` |
| `spotify.me.albums.save` | `PUT /v1/me/albums?ids=<id>` |
| `spotify.me.albums.remove` | `DELETE /v1/me/albums?ids=<id>` |
| `spotify.me.shows.save` | `PUT /v1/me/shows?ids=<id>` |
| `spotify.me.shows.remove` | `DELETE /v1/me/shows?ids=<id>` |
| `spotify.me.episodes.save` | `PUT /v1/me/episodes?ids=<id>` |
| `spotify.me.episodes.remove` | `DELETE /v1/me/episodes?ids=<id>` |
| `spotify.me.artists.follow` | `PUT /v1/me/following?type=artist&ids=<id>` |
| `spotify.me.artists.unfollow` | `DELETE /v1/me/following?type=artist&ids=<id>` |

Implementation sketch (mirroring the existing `spotifyWebTransport`
pattern in `Services/RPCManager.swift`):

```swift
case "spotify.me.tracks.save",
     "spotify.me.tracks.remove":
    let ids = (params.mapValue("ids")?.arrayValue ?? [])
        .compactMap { $0.stringValue }
        .joined(separator: ",")
    guard !ids.isEmpty else { return (.bool(false), nil) }
    let method = method.hasSuffix("save") ? "PUT" : "DELETE"
    let escaped = ids.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ids
    let viaWeb = await spotifyWebGenericMutation(
        url: "https://api.spotify.com/v1/me/tracks?ids=\(escaped)",
        method: method
    )
    // Invalidate `me/tracks/contains` cache for these IDs so the next
    // read reflects the new state.
    if viaWeb {
        for path in proxyGetCache.keys
            where path.hasPrefix("me/tracks/contains") {
            proxyGetCache.removeValue(forKey: path)
        }
    }
    return (.bool(viaWeb), nil)
```

The `spotifyWebGenericMutation` helper doesn't exist yet — refactor
`spotifyWebTransport` (currently hardcoded to the `/me/player/` path) to
accept an arbitrary URL, or write a sibling that mirrors its cooldown +
401-refresh handling.

### One subtle thing

The Car Thing optimistically flips the heart **before** sending the RPC.
If we return success (or never respond at all) it stays flipped. If we
respond with an error, the firmware likely reverts. So a no-op
"Unhandled" return today happens to *look* like success on screen even
though Spotify hasn't been updated. That's the user's "UI reacts just
doesn't sync" experience.

## 2. Library content fill-out

### Currently proxied

Every Car Thing home-screen call we've observed has a handler that
proxies straight through to the Web API and caches the response for
30 seconds per path. Specifically:

| RPC method | Spotify endpoint |
|------------|------------------|
| `spotify.me.profile` | `GET /v1/me` |
| `spotify.me.recentlyPlayed` | `GET /v1/me/player/recently-played?limit=N` |
| `spotify.me.topArtists` | `GET /v1/me/top/artists` |
| `spotify.me.topTracks` | `GET /v1/me/top/tracks` |
| `spotify.me.tracks` / `.savedTracks` | `GET /v1/me/tracks` (liked songs) |
| `spotify.me.playlists` | `GET /v1/me/playlists` |
| `spotify.me.albums` / `.savedAlbums` | `GET /v1/me/albums` |
| `spotify.me.shows` | `GET /v1/me/shows` |
| `spotify.me.episodes` | `GET /v1/me/episodes` |
| `spotify.me.tracks.contains` | `GET /v1/me/tracks/contains` |
| `spotify.me.albums.contains` | `GET /v1/me/albums/contains` |
| `spotify.album.get` / `.tracks` | `GET /v1/albums/<id>[/tracks]` |
| `spotify.playlist.get` / `.tracks` | `GET /v1/playlists/<id>[/tracks]` |
| `spotify.artist.get` | `GET /v1/artists/<id>` |
| `spotify.search` | `GET /v1/search?q=<q>&type=<types>` |
| `spotify.radio.mixes` | hardcoded empty (no public endpoint) |
| `spotify.image.fetch` | downloads from `i.scdn.co` |

That covers the home screen, the Liked Songs view, playlist contents,
album view, basic search. **Track changes on the Car Thing pull from
these on demand and the rows render.**

### What's likely missing

The Car Thing has UI for several deeper screens we haven't tested. From
looking at the firmware code (`src/pages/`, `src/components/`):

- **Artist detail page.** Tapping an artist on the Car Thing probably
  fetches their top tracks, albums, and related artists. The Web API
  endpoints exist (`GET /v1/artists/<id>/top-tracks?market=<m>`,
  `GET /v1/artists/<id>/albums`, `GET /v1/artists/<id>/related-artists`)
  but we haven't wired the RPC names. Likely names:
  `spotify.artist.topTracks`, `spotify.artist.albums`,
  `spotify.artist.relatedArtists`.
- **Browse / Categories.** Spotify's curated categories.
  `GET /v1/browse/categories`, `GET /v1/browse/categories/<id>/playlists`.
  Likely names: `spotify.browse.categories`,
  `spotify.browse.categoryPlaylists`.
- **Featured playlists / new releases.**
  `GET /v1/browse/featured-playlists`, `GET /v1/browse/new-releases`.
- **Personalized recommendations.** `GET /v1/recommendations` with seed
  parameters. The firmware might call this when generating a "made for
  you" view.
- **Queue manipulation.** Add to queue is
  `POST /v1/me/player/queue?uri=<uri>`. Reordering and "play next" are
  Spotify-Connect-only operations on the dealer protocol — not exposed
  via REST. Probably out of scope.
- **Playlist editing.** Rename, change description, add/remove tracks,
  reorder. All in the Web API (`PUT /v1/playlists/<id>`,
  `POST/DELETE /v1/playlists/<id>/tracks`) but moderately involved
  request shapes.
- **Podcast episode detail.** `GET /v1/episodes/<id>`. Listed as a
  potential gap; we don't know if the Car Thing's UI actually shows
  this.

### How to discover the exact names

The right way to fill these in is to **add a more verbose default-case
log line** in `handleCall`:

```swift
default:
    log.warning("Unhandled RPC method: \(method, privacy: .public)  params=\(self.describe(params), privacy: .public)")
    return (.nilValue, nil)
```

This already exists. Tap each Car Thing screen with the connector
running, watch for `Unhandled RPC method:` lines, and you'll see
exactly what the firmware calls. Then handlers are mostly one-liner
proxies.

## 3. Player source signaling (for the dual-entry path)

This expands on `non-spotify-sources.md`.

When the Mac connector eventually serves both Spotify Web *and*
MediaRemoteAdapter (Apple Music, browser playback, etc.), the Car
Thing's firmware needs to know which one is active so it can adjust
behavior — e.g.,:

- Don't try to display Spotify Connect device list when source is local
  media (no Connect device to switch to)
- Don't show "Save to Liked Songs" heart for non-Spotify tracks (the
  Spotify Web `me/tracks/save` endpoint won't accept an Apple Music
  track URI)
- Don't fetch library/search rows when source is local media — they're
  Spotify-only

### Signal #1: `device_type` in the cluster

The firmware caches `cluster.devices[active_device_id].device_type` as
`cachedActiveDeviceType`. Several places in the UI gate on this. Use it:

| Source | device_type | Effect |
|--------|-------------|--------|
| Spotify Web (active device = Mac, Phone, etc.) | "Computer", "Smartphone", etc. | Normal Spotify behavior |
| MediaRemote → Apple Music | "Computer" (still on the Mac) | But see signal #2 below |
| MediaRemote → browser / other | "Computer" | Same |

`device_type` alone isn't expressive enough.

### Signal #2: `is_phone_media` and `is_spotify_pending` on the item

The firmware has explicit support for non-Spotify sources via flags on
`item`:

```js
// from useSpotifyPlayerState
const currentIsPhoneMedia = currentPlaybackRef.current?.item?.is_phone_media;
const incomingIsPhoneMedia = data.item?.is_phone_media;
```

`is_phone_media: true` tells the firmware: "this is non-Spotify media
proxied from the connector device." Several code paths gate on this:

- `disableSpotifyFetch={isPhoneMedia || isSpotifyPending}` on the
  `SpotifyImage` → suppresses `spotify.image.fetch` (firmware expects
  artwork via the `media.nowPlaying.artwork` event instead). For our
  case we'd keep using `spotify.image.fetch` since we own that path.
- Hides Spotify Connect-specific UI (transfer playback button, etc.)
- Probably hides Like/Save heart (the spotify-only operations don't
  apply to Apple Music tracks)

When extending to MediaRemote sources, our cluster should set
`item.is_phone_media: true` for those tracks. The cluster builder
already accepts a generic structure; this is just one more field in the
synthesized `item`.

### Signal #3: the dedicated `media.nowPlaying.*` event topics

The firmware listens for a parallel set of topics intended for
phone-media playback:

| Topic | Meaning |
|-------|---------|
| `media.nowPlaying.update` | A new now-playing snapshot from the phone |
| `media.nowPlaying.artwork` | Artwork bytes (separate from `spotify.image.fetch`) |
| `media.nowPlaying.artwork.failed` | Artwork fetch failed |
| `phone.volume.update` | Phone's volume changed |

Receiving any of `media.nowPlaying.update` / `media.nowPlaying.artwork`
sets `isReceivingNowPlayingUpdates = true` for ~5s. While that flag is
true:

- `SpotifyImage` short-circuits `spotify.image.fetch` (assumes artwork
  arrives via the artwork event instead)
- The UI mode "knows" it's in phone-media mode

**Two viable shapes for dual-source.** Pick one:

**Option A: stay on the Spotify cluster path, just mark `is_phone_media`.**
Synthesize a Spotify-shaped cluster, set `item.is_phone_media: true`,
keep using `spotify.image.fetch` for art (we hosted-style serve from the
MediaRemote artwork via the synthetic `https://local.media/…` URL
trick from `non-spotify-sources.md`). Pros: small diff from current
code. Cons: still hits some Spotify-only firmware code paths that may
look weird (Connect device list, etc.).

**Option B: emit the dedicated `media.nowPlaying.*` events instead.**
Stop broadcasting `spotify.player.device_state_changed` while non-Spotify
is the source, and instead broadcast `media.nowPlaying.update` with a
phone-media-shaped payload (see firmware code at
`useSpotifyPlayerState.js:686` for the topic handler — we'd need to
match whatever shape it expects, which means reading more of that code).
Send artwork bytes via `media.nowPlaying.artwork` events directly. Pros:
cleaner separation, firmware behaves correctly. Cons: more firmware
code-archaeology to figure out the exact payload shape, and we'd need
two parallel cluster-build paths in `RPCManager`.

Option A is cheaper and probably "good enough" for personal use. Option
B is the right long-term answer if this connector ever gets shared more
widely.

## 4. Quick implementation order (suggested)

If picking this up, here's a reasonable sequence:

1. **Like/Dislike** (`spotify.me.tracks.save`/`.remove`). Two handlers,
   plus a `spotifyWebGenericMutation` helper. ~30 minutes including
   testing.
2. **Cache invalidation around save/unsave.** When a track is saved or
   removed, clear matching `me/tracks/contains` cache entries so the
   heart icon reflects the change on the next read.
3. **Verbose unhandled-method logging.** Already there — just exercise
   every Car Thing screen and harvest the missing method names.
4. **Per-discovery handler additions** for whatever falls out of step 3
   (artist detail, browse, queue add, etc.). Each is mostly a one-liner
   `proxyWebGet(path: …)`.
5. **`is_phone_media` flag.** Add to the cluster builder, drive from
   the connector's `source` enum. Small, no behavior change for Spotify
   path.
6. **MediaRemote-shaped cluster builder.** When source is local media,
   build a Spotify-like cluster from MediaRemote payload. Use synthetic
   `https://local.media/…` artwork URLs.
7. **Source picker in `fetchSpotifyWebPlayerState`** so the broadcast
   loop transparently switches between Web API state and MediaRemote
   state based on what's actually playing.

## Related project memories / docs

- `album-art.md` — why we ship 64×64 and not 300×300
- `non-spotify-sources.md` — the MediaRemoteAdapter integration sketch
- `setup-spotify-client.md` — how to register your own Spotify app
- `project_nocturne_ui_cluster.md` (memory) — the topic name and
  required cluster fields
- `reference_msgpack_to_json_bridge.md` (memory) — binary fields must
  be base64 strings
- `reference_rpc_response_type.md` (memory) — RPC reply envelope
  must use `type:"result"`
