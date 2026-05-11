import Foundation
import os
import Security

/// Persists small bits of state for the connector. Tokens go into the macOS Keychain;
/// flags like "setup complete" go into UserDefaults so they survive without prompting.
///
/// Mirrors AUTH_SESSION_PATH and SETUP_STATE_PATH from src/server/config.ts.
final class SessionStore {
    private let log = Log.make(for: "SessionStore")

    static let shared = SessionStore()

    private let service = "com.usenocturne.connector.mac"
    private let supabaseAccount = "supabase-session"
    private let spotifyAccount = "spotify-credentials"

    private let setupCompleteKey = "nocturne.setupComplete"
    private let analyticsEnabledKey = "nocturne.analyticsEnabled"

    // MARK: - Supabase tokens

    func loadSupabaseTokens() -> SupabaseTokens? {
        guard let data = readKeychain(account: supabaseAccount) else { return nil }
        return try? JSONDecoder().decode(SupabaseTokens.self, from: data)
    }

    func saveSupabaseTokens(_ tokens: SupabaseTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        writeKeychain(account: supabaseAccount, data: data)
    }

    func clearSupabaseTokens() {
        deleteKeychain(account: supabaseAccount)
    }

    // MARK: - Spotify credentials

    func loadSpotifyCredentials() -> SpotifyCredentials? {
        guard let data = readKeychain(account: spotifyAccount) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpotifyCredentials.self, from: data)
    }

    func saveSpotifyCredentials(_ credentials: SpotifyCredentials) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(credentials) else { return }
        writeKeychain(account: spotifyAccount, data: data)
    }

    func clearSpotifyCredentials() {
        deleteKeychain(account: spotifyAccount)
    }

    // MARK: - Setup flags

    var setupComplete: Bool {
        get { UserDefaults.standard.bool(forKey: setupCompleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: setupCompleteKey) }
    }

    var analyticsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: analyticsEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: analyticsEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: analyticsEnabledKey) }
    }

    // MARK: - Keychain primitives

    private func readKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private func writeKeychain(account: String, data: Data) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                log.warning("Keychain add failed for \(account, privacy: .public): \(addStatus, privacy: .public)")
            }
        } else if status != errSecSuccess {
            log.warning("Keychain update failed for \(account, privacy: .public): \(status, privacy: .public)")
        }
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
