import Foundation
import os
import Combine
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

/// Spotify Authorization Code + PKCE flow. We used to use RFC 8628 device
/// authorization, but Spotify has tightened that grant type's eligibility
/// (it now refuses with `unauthorized_client` for non-hardware-device apps).
/// PKCE is the standard recommended flow for native desktop apps and
/// avoids the grant-type gatekeeping entirely.
///
/// Flow:
///   1. Generate `code_verifier` (random 64-byte base64url string) and
///      `code_challenge = SHA256(code_verifier)` (base64url).
///   2. Start a one-shot localhost HTTP listener on 127.0.0.1:8888.
///   3. Open the user's browser at `accounts.spotify.com/authorize?...`.
///   4. User logs in → Spotify redirects to `http://127.0.0.1:8888/callback?code=...`.
///   5. Listener catches the code, we exchange it + code_verifier at
///      `/api/token` for an access_token + refresh_token.
///
/// The redirect URI here must match exactly what's registered in the
/// Spotify dashboard for this client_id (see Configuration.swift). Default:
/// `http://127.0.0.1:8888/callback`.
@MainActor
final class SpotifyService: ObservableObject {
    private let log = Log.make(for: "SpotifyService")
    private let api = APIClient()
    private let store = SessionStore.shared

    @Published private(set) var authState: SpotifyAuthState = .idle

    private var pkceTask: Task<Void, Never>?
    private var callbackServer: LocalhostCallbackServer?
    private var refreshTimer: Timer?

    private static let refreshInterval: TimeInterval = 30 * 60
    private static let redirectURI = "http://127.0.0.1:8888/callback"
    private static let callbackPort: UInt16 = 8888

    // MARK: - Lifecycle

    func bootstrap() async {
        guard let creds = store.loadSpotifyCredentials() else {
            authState = .idle
            return
        }
        let needsRefresh = creds.expiresAt < Date().addingTimeInterval(5 * 60)
        if needsRefresh {
            do {
                try await refreshAccessToken(using: creds)
            } catch {
                log.warning("Spotify token refresh on launch failed: \(error.localizedDescription, privacy: .public)")
                authState = .idle
                return
            }
        }
        let updated = store.loadSpotifyCredentials() ?? creds
        authState = .linked(displayName: updated.displayName)
        startRefreshTimer()
    }

    // MARK: - Authorize (Authorization Code + PKCE)

    /// Kicks off the PKCE flow. Method name retained for compatibility with
    /// the UI buttons that previously called the device-auth version.
    func startDeviceAuthorization() async throws {
        authState = .loading
        log.info("Starting Spotify PKCE auth flow")

        // 1. Generate PKCE values.
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.pkceChallenge(from: codeVerifier)
        let stateToken = Self.randomURLSafe(length: 32)

        // 2. Start the localhost listener BEFORE opening the browser so we
        // don't race the redirect.
        let server = LocalhostCallbackServer(port: Self.callbackPort)
        do {
            try server.start()
        } catch {
            authState = .idle
            log.error("Failed to bind localhost callback: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.callbackServer = server

        // 3. Construct the Spotify authorize URL and open it.
        var comp = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "state", value: stateToken),
            URLQueryItem(name: "scope", value: AppConfig.spotifyScopes.joined(separator: " "))
        ]
        guard let authURL = comp.url else {
            await teardownCallbackServer()
            authState = .idle
            throw HTTPError.status(0, "Failed to build authorize URL")
        }
        // Surface in the UI via the existing `.polling` case so SpotifyLinkBanner
        // can show "Authorize on Spotify" with the URL. userCode isn't used by
        // PKCE so we leave it as a placeholder dash.
        authState = .polling(
            deviceCode: "",
            userCode: "—",
            verificationURI: authURL.absoluteString,
            interval: 0
        )

        #if canImport(AppKit)
        NSWorkspace.shared.open(authURL)
        #endif

        // 4. Wait for the redirect with `code=...`.
        let params: [String: String]
        do {
            params = try await server.waitForCallback()
        } catch {
            await teardownCallbackServer()
            authState = .idle
            log.error("OAuth callback failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        await teardownCallbackServer()

        if let returnedState = params["state"], returnedState != stateToken {
            authState = .idle
            throw HTTPError.status(400, "OAuth state mismatch")
        }
        if let err = params["error"] {
            authState = .idle
            throw HTTPError.status(400, "Spotify returned error: \(err) — \(params["error_description"] ?? "")")
        }
        guard let code = params["code"] else {
            authState = .idle
            throw HTTPError.status(400, "OAuth callback missing 'code'")
        }

        // 5. Exchange the code + code_verifier for tokens.
        try await exchangeAuthorizationCode(code: code, verifier: codeVerifier)
    }

    func cancelAuthorization() {
        pkceTask?.cancel()
        pkceTask = nil
        Task { @MainActor [weak self] in await self?.teardownCallbackServer() }
        authState = .idle
    }

    func disconnect() async {
        pkceTask?.cancel()
        pkceTask = nil
        await teardownCallbackServer()
        stopRefreshTimer()
        store.clearSpotifyCredentials()
        authState = .idle
    }

    private func teardownCallbackServer() async {
        callbackServer?.stop()
        callbackServer = nil
    }

    // MARK: - Token exchange (PKCE)

    private func exchangeAuthorizationCode(code: String, verifier: String) async throws {
        let body = api.encodeForm([
            "client_id": AppConfig.spotifyClientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier
        ])
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await api.request(
                URL(string: "https://accounts.spotify.com/api/token")!,
                method: "POST",
                body: body,
                contentType: "application/x-www-form-urlencoded"
            )
        } catch {
            authState = .idle
            throw error
        }
        guard (200..<300).contains(http.statusCode) else {
            authState = .idle
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            log.warning("Token exchange HTTP \(http.statusCode, privacy: .public): \(bodyText, privacy: .public)")
            throw HTTPError.status(http.statusCode, bodyText)
        }
        let resp = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        guard let access = resp.access_token,
              let refresh = resp.refresh_token,
              let expiresIn = resp.expires_in else {
            authState = .idle
            throw HTTPError.status(0, "Malformed token response")
        }

        var creds = SpotifyCredentials(
            accessToken: access,
            refreshToken: refresh,
            scope: resp.scope,
            tokenType: resp.token_type ?? "Bearer",
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            displayName: nil
        )
        store.saveSpotifyCredentials(creds)

        // Fetch display name for the linked-state banner. Non-fatal if it fails.
        var displayName: String? = nil
        do {
            displayName = try await fetchDisplayName(accessToken: access)
            creds = SpotifyCredentials(
                accessToken: creds.accessToken,
                refreshToken: creds.refreshToken,
                scope: creds.scope,
                tokenType: creds.tokenType,
                expiresAt: creds.expiresAt,
                displayName: displayName
            )
            store.saveSpotifyCredentials(creds)
        } catch {
            log.warning("Profile fetch failed: \(error.localizedDescription, privacy: .public)")
        }

        authState = .linked(displayName: displayName)
        startRefreshTimer()
    }

    // MARK: - PKCE helpers

    /// Generate a high-entropy code_verifier (RFC 7636 section 4.1):
    /// 43-128 chars from the unreserved URL set. We use 64 bytes of random
    /// data, base64url-encoded without padding (yields ~86 chars).
    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// SHA-256 hash of the verifier, base64url-encoded without padding.
    private static func pkceChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(hash))
    }

    /// Random URL-safe string used as the OAuth `state` parameter to detect
    /// callback tampering / cross-site replay.
    private static func randomURLSafe(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: SpotifyService.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let creds = self.store.loadSpotifyCredentials() else { return }
                try? await self.refreshAccessToken(using: creds)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshAccessToken(using creds: SpotifyCredentials) async throws {
        let body = api.encodeForm([
            "client_id": AppConfig.spotifyClientID,
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken
        ])
        let (data, http) = try await api.request(
            URL(string: "https://accounts.spotify.com/api/token")!,
            method: "POST",
            body: body,
            contentType: "application/x-www-form-urlencoded"
        )

        let resp = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        guard (200..<300).contains(http.statusCode),
              let access = resp.access_token,
              let expiresIn = resp.expires_in else {
            if resp.error == "invalid_grant" {
                store.clearSpotifyCredentials()
                authState = .idle
            }
            throw HTTPError.status(http.statusCode, resp.error_description ?? resp.error)
        }

        let refreshed = SpotifyCredentials(
            accessToken: access,
            refreshToken: resp.refresh_token ?? creds.refreshToken,
            scope: resp.scope ?? creds.scope,
            tokenType: resp.token_type ?? creds.tokenType,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            displayName: creds.displayName
        )
        store.saveSpotifyCredentials(refreshed)
        authState = .linked(displayName: refreshed.displayName)
    }

    // MARK: - Profile

    private struct WebProfile: Decodable {
        let display_name: String?
        let id: String?
    }

    private func fetchDisplayName(accessToken: String) async throws -> String? {
        let (data, http) = try await api.request(
            URL(string: "https://api.spotify.com/v1/me")!,
            method: "GET",
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        guard (200..<300).contains(http.statusCode) else { return nil }
        let me = try? JSONDecoder().decode(WebProfile.self, from: data)
        return me?.display_name ?? me?.id
    }
}
