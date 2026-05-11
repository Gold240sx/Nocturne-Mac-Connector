import Foundation

/// Minimal async HTTP client. Mirrors the wrapper in src/client/api.ts but used
/// to talk directly to the upstream services (Nocturne site, Supabase, Spotify)
/// since there is no local server hop on macOS.
struct APIClient {
    let session: URLSession

    init(session: URLSession = APIClient.makeSession()) {
        self.session = session
    }

    /// macOS 14+ prefers HTTP/3 / QUIC for HTTPS by default, but some
    /// networks (including common Wi-Fi captive portals and content filters)
    /// silently drop UDP/443 mid-handshake — the symptoms look like
    /// `TLS error (security error 50)` + `Connection failed reason -1` on
    /// `api.spotify.com` even though plain HTTPS to the same hosts works
    /// fine in a browser. Forcing the session to HTTP/2 over TCP (no QUIC)
    /// sidesteps the issue.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = .shared
        return URLSession(configuration: config)
    }

    func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Force HTTP/2 over TCP — don't even probe HTTP/3 / QUIC. Some networks
        // and macOS content filters silently break the QUIC UDP handshake on
        // port 443, which manifests as `TLS error (security error 50)` and
        // -1005 "network connection was lost" on api.spotify.com requests
        // (while plain HTTPS to the same hosts works fine in browsers).
        request.assumesHTTP3Capable = false
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        return (data, http)
    }

    func json<T: Decodable>(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        let (data, http) = try await request(url, method: method, headers: headers, body: body)
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)
            throw HTTPError.status(http.statusCode, text)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    func encodeForm(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }
}
