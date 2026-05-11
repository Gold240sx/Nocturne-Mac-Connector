import Foundation
import os
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Spotify Device Authorization flow, ported from the core paths of
/// src/server/services/spotify-service.ts.
///
/// The full original service exposes a large Spotify Web/Internal API surface that
/// gets bridged through to the Car Thing over RFCOMM. Here we only implement the
/// pieces the macOS UI needs: device auth, polling, refresh, sign-out, and a tiny
/// "Get Current User's Profile" call to surface the display name.
@MainActor
final class SpotifyService: ObservableObject {
    private let log = Log.make(for: "SpotifyService")
    private let api = APIClient()
    private let store = SessionStore.shared

    @Published private(set) var authState: SpotifyAuthState = .idle

    private var pollingTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    private static let refreshInterval: TimeInterval = 30 * 60

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

    // MARK: - Authorize (RFC 8628 device flow)

    func startDeviceAuthorization() async throws {
        authState = .loading
        log.info("Starting Spotify device-auth flow")

        let comp = URLComponents(string: "https://accounts.spotify.com/oauth2/device/authorize")!
        let formBody = api.encodeForm([
            "client_id": AppConfig.spotifyClientID,
            "scope": AppConfig.spotifyScopes.joined(separator: " ")
        ])

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await api.request(
                comp.url!,
                method: "POST",
                body: formBody,
                contentType: "application/x-www-form-urlencoded"
            )
        } catch {
            authState = .idle
            log.warning("Spotify device-auth request failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        guard (200..<300).contains(http.statusCode) else {
            authState = .idle
            let body = String(data: data, encoding: .utf8) ?? ""
            log.warning("Spotify device-auth HTTP \(http.statusCode, privacy: .public): \(body, privacy: .public)")
            throw HTTPError.status(http.statusCode, body)
        }
        let resp = try JSONDecoder().decode(SpotifyDeviceAuthResponse.self, from: data)
        let interval = resp.interval ?? 5
        authState = .polling(
            deviceCode: resp.device_code,
            userCode: resp.user_code,
            verificationURI: resp.verification_uri,
            interval: interval
        )

        // Open the verification URL in the user's default browser.
        let urlString = resp.verification_uri + "?code=" + resp.user_code
        if let url = URL(string: urlString) {
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        }

        startPolling(deviceCode: resp.device_code, interval: interval)
    }

    func cancelAuthorization() {
        pollingTask?.cancel()
        pollingTask = nil
        authState = .idle
    }

    func disconnect() async {
        pollingTask?.cancel()
        pollingTask = nil
        stopRefreshTimer()
        store.clearSpotifyCredentials()
        authState = .idle
    }

    // MARK: - Polling

    private func startPolling(deviceCode: String, interval: Int) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { return }
                let outcome = await self.pollOnce(deviceCode: deviceCode)
                switch outcome {
                case .pending:
                    continue
                case .expired:
                    self.authState = .idle
                    return
                case .linked:
                    return
                case .failed(let err):
                    self.log.error("Spotify polling error: \(err.localizedDescription, privacy: .public)")
                    self.authState = .idle
                    return
                }
            }
        }
    }

    private enum PollOutcome { case pending, expired, linked, failed(Error) }

    private func pollOnce(deviceCode: String) async -> PollOutcome {
        do {
            let body = api.encodeForm([
                "client_id": AppConfig.spotifyClientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            let (data, _) = try await api.request(
                URL(string: "https://accounts.spotify.com/api/token")!,
                method: "POST",
                body: body,
                contentType: "application/x-www-form-urlencoded"
            )
            let resp = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)

            if let err = resp.error {
                switch err {
                case "authorization_pending", "slow_down": return .pending
                case "expired_token": return .expired
                default: return .failed(HTTPError.status(400, resp.error_description ?? err))
                }
            }

            guard let access = resp.access_token,
                  let refresh = resp.refresh_token,
                  let expiresIn = resp.expires_in else {
                return .failed(HTTPError.status(0, "Malformed token response"))
            }

            let creds = SpotifyCredentials(
                accessToken: access,
                refreshToken: refresh,
                scope: resp.scope,
                tokenType: resp.token_type ?? "Bearer",
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                displayName: nil
            )
            store.saveSpotifyCredentials(creds)

            // Best-effort fetch the display name for the linked-state banner.
            var displayName: String? = nil
            do {
                displayName = try await fetchDisplayName(accessToken: access)
                let withName = SpotifyCredentials(
                    accessToken: creds.accessToken,
                    refreshToken: creds.refreshToken,
                    scope: creds.scope,
                    tokenType: creds.tokenType,
                    expiresAt: creds.expiresAt,
                    displayName: displayName
                )
                store.saveSpotifyCredentials(withName)
            } catch {
                log.warning("Profile fetch failed: \(error.localizedDescription, privacy: .public)")
            }

            authState = .linked(displayName: displayName)
            startRefreshTimer()
            return .linked
        } catch {
            return .failed(error)
        }
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
