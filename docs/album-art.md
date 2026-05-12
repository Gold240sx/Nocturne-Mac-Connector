# Album Art — Why Only 64×64

## TL;DR

The Mac connector serves only the **64×64** album art URL to the Car Thing,
even though Spotify returns 300×300 and 640×640 sizes too. This is a
firmware-side constraint we can't bridge from our side. 64×64 up-scales
softly to the 280×280 NowPlaying slot but it's the only size that renders
at all.

If you ever pick up where this left off, the *only* path to sharper art is
patching `usenocturne/nocturne-ui` itself — see
[Path forward (firmware-only)](#path-forward-firmware-only).

## The data flow

```
Spotify Web API /me/player
         │
         ▼
RPCManager.buildClusterFromRESTPlayer
   picks one of image_url (small/medium/large) based on imageQualityLevel
         │
         ▼  type:result, msgpack chunked over RFCOMM
nocturned  (Rust daemon on Car Thing)
   re-tags type:result → type:response
   converts msgpack → JSON (binary becomes number array)
         │
         ▼  local WebSocket
nocturne-ui  (React app inside Car Thing WebView)
   useSpotifyPlayerState parses cluster → builds item.album.images=[{url}]
   NowPlaying.jsx renders <SpotifyImage images={...} />
   SpotifyImage's useEffect → loadImage(url) → spotify.image.fetch RPC
         │
         ▼  (back over RFCOMM)
RPCManager handler downloads image, returns base64 string
         │
         ▼
nocturne-ui ImageLoader queue
   await fetchImageFn(url)               ← gets the base64
   await extractColorsFromImageData(b64) ← canvas pass for gradient colors
   setCache(url, base64, colors)
   listener.resolve({data, colors})
         │
         ▼
SpotifyImage setCurrentSrc(`data:image/jpeg;base64,${imageData}`)
   <img src=… /> renders inside an embedded WebView
```

## Where it breaks for medium/large

Two failure modes empirically observed; the Car Thing's WebView never
recovers from either:

### 1. Color-extraction canvas pass hangs silently

`extractColorsFromImageData(b64)` in `src/utils/colorExtractor.js`:

```js
return new Promise((resolve, reject) => {
  const img = new Image();
  img.onload = () => resolve(extractColorsFromCanvasImage(img));
  img.onerror = () => resolve(["#191414", ...]);  // fallback palette
  img.src = `data:image/jpeg;base64,${imageData}`;
});
```

On the Car Thing's embedded WebView (small device, limited memory), large
`data:` URLs of ~30KB+ base64 sometimes never fire `onload` *or* `onerror`.
The Promise hangs forever. The queue processor `_processItem` awaits this
Promise, so the listener never resolves. `currentSrc` stays at the
fallback (gray music-note placeholder), or — when the small image rendered
first — keeps showing the small.

Sizes empirically observed:

| Spotify size | Base64 length | Result on Car Thing WebView |
|--------------|---------------|------------------------------|
| 64×64        | ~3-7 KB        | ✅ Renders                  |
| 300×300      | ~30-50 KB      | ⚠️  Mostly hangs            |
| 640×640      | ~100-150 KB    | ❌ Always hangs             |

### 2. Render-cycle thrash

`SpotifyImage`'s effect:

```js
useEffect(() => {
  if (currentImageUrlRef.current !== imageUrl) cancelRequest(currentImageUrlRef.current);
  currentImageUrlRef.current = imageUrl;
  if (imageUrl) loadImageData();
}, [imageUrl, loadImageData, fallbackSrc, cancelRequest, cleanupBlobUrl]);
```

`loadImageData` is a `useCallback` whose deps include `currentSrc` and
`isLoading`. The effect itself updates both, so each load attempt
recreates `loadImageData`, refires the effect, re-runs the load, cancels
the in-flight request mid-color-extraction, queues a fresh fetch. We
observed dozens of `spotify.image.fetch` for the same URL within seconds
when this loop triggers.

Our level-progression approach (small → medium → large with re-broadcasts)
made this worse — every URL swap was extra fuel for the cycle.

## Why we landed at 64×64-only

- ✅ Decodes cleanly in the WebView — no color-extraction hang
- ✅ Single URL per track — no thrash from URL swaps
- ✅ Single `spotify.image.fetch` per track (plus whatever the firmware
  re-queries from render cycles, but the queue resolves quickly so the
  cycle terminates fast)
- ❌ Visually upscaled from 64×64 to 280×280 (≈4.4×) → softer than ideal
- ❌ We're shipping less data than we could

Spotify Web API returns all three sizes in `item.album.images` so we
already *have* the medium/large URLs in hand. We choose not to serve them.

## What we tried (in order)

1. **`type: "result"` envelope + binary `data`** — silently dropped by the
   firmware's WebSocket dispatcher (only handles `type: "response"`).
2. **`type: "response"` + binary** — dropped by `nocturned`'s msgpack
   parser (the daemon's serde enum uses `#[serde(rename = "result")]` and
   re-tags downstream; "response" doesn't match any variant).
3. **`type: "result"` + binary** — `nocturned`'s `rmpv_to_json` converts
   msgpack `Binary` to a JSON number array, which fails the firmware's
   `instanceof Uint8Array` check on `result.data`.
4. **`type: "result"` + base64 string** — ✅ correct wire shape; the
   string round-trips through msgpack→JSON unchanged. With this in place
   plus the cluster topic/`devices` fixes, the 64×64 URL renders. This is
   what's shipping.
5. **`type: "result"` + base64 + serve medium URL** — handler returns
   30 KB base64, `nocturned` forwards, firmware never resolves the
   listener (color-extraction hang on the WebView's canvas pass). Stays
   on gray fallback.
6. **Progressive enhancement (small → medium after 3s)** — small renders
   first, then we swap URL to medium. The firmware's `cancelRequest`
   aborts the in-flight medium fetch on URL change, and on retries the
   color-extraction loop triggers. Medium sometimes renders, sometimes
   doesn't. The user reported it still looked low quality even when the
   logs said the bump happened.
7. **Medium-only** — never renders. The small-first sequence had been
   "priming" something (likely just keeping `currentSrc` non-fallback so
   the render didn't blank), so removing it returned the gray
   placeholder.

Settled on **64×64 only, no progression**.

## Path forward (firmware-only)

Two clean fixes, both require modifying `usenocturne/nocturne-ui`:

### Option A — skip color extraction for the now-playing slot

The 280×280 NowPlaying art doesn't actually need extracted colors (the
gradient comes from `useGradientState` which has its own pipeline). Have
`SpotifyImage` accept a prop `skipColorExtraction={true}` and short-circuit
the `extractColorsFromImageData` await in `_processItem`. The image renders
as soon as the bytes arrive; no canvas pass.

### Option B — render the image *before* awaiting color extraction

`_processItem` could `setCache(url, result.data)` *before* `await
extractColorsFromImageData`, fire the listener resolve immediately, and
let the color extraction complete in the background to populate
`cache.colors` asynchronously. The image displays the moment the bytes
arrive; the gradient might lag a fraction of a second but won't block.

Either fix lets us pass the medium URL (or even the large) without
hanging. From our side nothing changes — flip `imageQualityLevel` from
`0` back to `1` in `RPCManager` and the cluster will start carrying the
300×300 URL.

## Files

- `Nocturne-Mac/Services/RPCManager.swift::buildClusterFromRESTPlayer` —
  picks the URL from `item.album.images` based on `imageQualityLevel`.
- `Nocturne-Mac/Services/RPCManager.swift::pickImageURL` — implements the
  small/medium/large preference (currently locked to small).
- `Nocturne-Mac/Services/RPCManager.swift` `spotify.image.fetch` handler —
  downloads the image bytes from Spotify CDN and returns base64 string.

## Related project memories

- `reference_rpc_response_type.md` — the `type:"result"` vs `"response"`
  trap (two layers, two different expectations)
- `reference_msgpack_to_json_bridge.md` — why binary fields must be
  base64 strings (nocturned converts msgpack `bin` to JSON number arrays)
- `project_nocturne_ui_cluster.md` — the cluster topic + `devices` map
  the firmware actually reads
