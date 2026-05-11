import Foundation

struct NocturneUser: Codable, Equatable, Identifiable {
    let id: String
    let email: String?
}

/// Mirrors AuthService.getStatus() from src/server/services/auth-service.ts.
struct AuthStatus: Equatable {
    var authenticated: Bool = false
    var user: NocturneUser? = nil
    var isInitializing: Bool = false
    var passwordResetPending: Bool = false
    var setupComplete: Bool = false
}

/// Response body from `${NOCTURNE_SITE_URL}/api/pair/redeem`.
struct PairRedeemResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let error: String?
}

/// Stored Supabase tokens. Equivalent to AUTH_SESSION_PATH JSON in the original.
struct SupabaseTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

/// Supabase /auth/v1/user response (subset).
struct SupabaseUser: Decodable {
    let id: String
    let email: String?
}

/// Supabase /auth/v1/token response (subset).
struct SupabaseTokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let user: SupabaseUser?
    let error: String?
    let error_description: String?
    let msg: String?
    let message: String?
}
