import Foundation

/// Compile-time configuration mirrored from the original src/server/config.ts.
enum AppConfig {
    static let supabaseURL = URL(string: "https://qrrtjdmdclkpssjzhzhw.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_sUnSM7qjeWn6rcI9x_fmWg_VJddosT-"

    // ⚠️ BRING YOUR OWN SPOTIFY CLIENT ID.
    //
    // If you forked this repo to build it for yourself, you MUST register
    // your own app at https://developer.spotify.com/dashboard and paste
    // its Client ID here. Don't ship someone else's client_id.
    //
    // Three reasons:
    //   1. Spotify's quotas are per-app, not per-user. A shared client_id
    //      burns out fast under multiple developers' traffic and trips
    //      the rate limiter for everyone tied to it. (Symptom: 429
    //      "API rate limit exceeded" on the very first call after a
    //      fresh OAuth — we hit this in development, see git history.)
    //   2. New Spotify apps are in Development Mode — limited to 25
    //      users on a whitelist that only the app owner edits. Tokens
    //      issued to non-whitelisted users 403 on most endpoints.
    //   3. The client_id ships in the binary. You don't want your build
    //      depending on someone else's revocation decisions.
    //
    // Setup walkthrough: docs/setup-spotify-client.md
    //
    // Don't store a client_secret here — this app uses Authorization Code
    // + PKCE which has no secret.
    static let spotifyClientID = "06b976f397ee4ce8a78dc511976a3baf"

    static let nocturneSiteURL = URL(string: "https://main-nocturne-site.vantalabs.workers.dev/")!
    static let otaServerURL = URL(string: "https://ota.usenocturne.com")!

    /// RFCOMM Serial Port Profile UUID. Used to find the Car Thing's serial channel.
    static let rfcommUUID = "00001101-0000-1000-8000-00805f9b34fb"

    /// Spotify OAuth scopes — only currently-documented values. The previous
    /// list had `playlist-modify`, `playlist-read`, `user-modify`,
    /// `user-modify-private`, `user-personalized`, `user-read-birthdate`, and
    /// `user-read-play-history` — none of which are real Spotify scopes (some
    /// were deprecated, some never existed). When Spotify gets any unknown
    /// scope in the device-auth request it returns
    /// `{"error":"invalid_scope","error_description":"Invalid scope requested"}`
    /// for the entire request — so a single bogus entry kills the whole flow.
    static let spotifyScopes: [String] = [
        "app-remote-control",
        "playlist-modify-private",
        "playlist-modify-public",
        "playlist-read-collaborative",
        "playlist-read-private",
        "streaming",
        "ugc-image-upload",
        "user-follow-modify",
        "user-follow-read",
        "user-library-modify",
        "user-library-read",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "user-read-email",
        "user-read-playback-position",
        "user-read-playback-state",
        "user-read-private",
        "user-read-recently-played",
        "user-top-read"
    ]

    static var connectorVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
