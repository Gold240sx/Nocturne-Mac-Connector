# Setup — Bring Your Own Spotify Client ID

**You cannot use my client ID.** Anyone forking this repo to build the
connector for themselves needs to register their own app at Spotify's
developer portal and paste the resulting Client ID into
`Nocturne-Mac/Utilities/Configuration.swift`. There are real-world reasons
this is not optional — they're not about ego, they're about how Spotify's
quota system works.

## Why you have to bring your own client ID

1. **Quotas are per-app, not per-user.** Every authorized user funnels their
   API calls through one client ID's bucket. A handful of friendly
   developers sharing one app id can — and will, in testing — burn through
   the quota and trip Spotify's anti-abuse heuristics. When that happens
   *everyone* using that app id sees `429 "API rate limit exceeded"` even
   on the first call after a fresh OAuth flow. We spent multiple sessions
   debugging this exact scenario before realizing the fix was to register
   a new app.
2. **Development Mode is a whitelist.** A freshly-created Spotify app is
   in "Development Mode" — limited to 25 explicitly listed users. Tokens
   issued to non-listed users return 403/429 on most endpoints. The
   owner of the client ID is the only one who can add users to that list.
   Whoever holds the dashboard credentials decides who can use the app.
3. **The client ID is in the binary.** It's baked into
   `Configuration.swift` and ships in every build. There's no
   "configure at first run" UI — by design, because Spotify's PKCE flow
   for native apps doesn't keep secrets on the client.
4. **Revocation is one-click.** If a client ID gets abused, the dashboard
   owner can rotate or disable it, breaking *all* clients tied to it.
   You don't want your app dependent on someone else's revocation
   decisions.

## Step-by-step setup

### 1. Register a Spotify app

1. Go to <https://developer.spotify.com/dashboard>.
2. Log in with the Spotify account that should *own* this app (this is
   the only account that can manage the user whitelist and rotate the
   secret).
3. Click **Create app**.
4. Fill in:
   - **App name:** anything (e.g. "Nocturne-Mac Connector").
   - **App description:** anything.
   - **Website:** leave empty or use your repo URL.
   - **Redirect URIs:** add `http://127.0.0.1:8888/callback`.
     This must match *exactly*. Spotify's dashboard rejects bare
     `http://localhost` for new apps now — use the IP form with port and
     path.
   - **APIs Used:** check **Web API** *only*. **Do not** check
     **iOS SDK** or set a **Bundle ID** — the iOS SDK flag forces the
     iOS SDK redirect-callback flow and Spotify will refuse our
     Authorization Code + PKCE grant with
     `unauthorized_client / "Client not allowed"`.
   - **Web Playback SDK / Android packages / Bundle IDs:** leave empty
     and unchecked.
5. Save.

### 2. Add yourself (and anyone else who'll use this build) as a user

1. From your new app's dashboard page, open **Settings → User Management**.
2. Click **Add User**.
3. Enter the Spotify display name and email address of each user.
4. Save.

Without this step, the OAuth flow completes and a token is issued, but
every API call returns 403/429. The error body literally says
`"API rate limit exceeded"` which is misleading — it's actually a
whitelist-membership check failing.

### 3. Copy the Client ID into the app

1. Back on the app's dashboard page, copy the **Client ID** string
   (under your app name; it's a 32-char hex value).
2. **Do not** copy the Client Secret. This app uses Authorization
   Code + PKCE — there's no secret in the flow. Storing a secret in a
   client-side binary is insecure anyway.
3. Open `Nocturne-Mac/Utilities/Configuration.swift`.
4. Replace the value of `spotifyClientID`:

   ```swift
   static let spotifyClientID = "<your-32-char-client-id-here>"
   ```

5. Build.

### 4. Verify it works

1. Launch the app. The Dashboard's Spotify card should say "Link Spotify".
2. Click **Link Spotify**. Your default browser opens to
   `accounts.spotify.com/authorize?...`. Log in if needed and approve
   the requested scopes.
3. The browser redirects to `http://127.0.0.1:8888/callback?code=...`,
   which the app catches via its local one-shot HTTP listener (see
   `Services/LocalhostCallbackServer.swift`).
4. The app exchanges the code for tokens at
   `accounts.spotify.com/api/token` and stores them in the keychain.
5. The Dashboard card flips to "Spotify linked".
6. Start playing something in Spotify.app. The Mac connector's
   broadcast loop will fetch `/v1/me/player` and start streaming state
   to the Car Thing.

If step 4 returns `unauthorized_client / "Client not allowed"`, revisit
step 1 — the iOS SDK flag or a Bundle ID is set on the app.

If `/me/player` returns 403/429 with `"API rate limit exceeded"`,
revisit step 2 — you're not in the User Management whitelist.

## What the app does with your tokens

- **Access token + refresh token** stored in the macOS keychain via
  `Services/SessionStore.swift`. Re-acquired silently every ~30 min via
  the refresh token; the user only sees the OAuth flow once.
- **Token used for:**
  - `GET /v1/me/player` — every 10s (cached) for the cluster broadcast
  - `GET /v1/me/playlists`, `me/recently-played`, `me/top/*`, etc. —
    on demand when the Car Thing's home screen asks (cached 30s per path)
  - `PUT /v1/me/player/play` and `/pause`, `POST /v1/me/player/next`
    and `/previous`, `PUT /v1/me/player/volume`, `/seek`, `/shuffle`,
    `/repeat` — when you tap transport buttons on the Car Thing
  - `GET /v1/me`, `me/tracks/contains`, etc. — for the UI's "is this
    saved?" indicators
- **Never sent anywhere except `api.spotify.com` and
  `accounts.spotify.com`.** The connector talks to Spotify directly; the
  Car Thing receives the *cluster shape* but not the access token.

## Rotating the client ID

If you ever need to swap to a new client ID (e.g., the old one got
throttled, or you're forking for a different audience):

1. Register the new app (steps 1-3 above).
2. Update `Configuration.swift::spotifyClientID`.
3. In the Mac app, click **Disconnect** on the Spotify card. This is
   important — the keychain still holds a token issued by the *old*
   client ID, and Spotify will keep treating requests as coming from the
   old app id (and applying the old quota) until that token is replaced.
4. Click **Link Spotify** to get a fresh token bound to the new client
   ID.

This caught us during development too — the old client ID's penalty
followed the token, not the code.
