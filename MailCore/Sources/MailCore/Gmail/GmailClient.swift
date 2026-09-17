import Foundation

/// Thin async Gmail REST client for one account. Handles auth headers,
/// 401 → token refresh retry, and 429/5xx backoff.
public struct GmailClient: Sendable {
    public let accountId: String
    private let tokens: TokenManager
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    public init(accountId: String, tokens: TokenManager) {
        self.accountId = accountId
        self.tokens = tokens
    }

    // MARK: - Endpoints

    public struct Profile: Decodable, Sendable {
        public let emailAddress: String
        public let historyId: String
    }

    public func profile() async throws -> Profile {
        try await get("profile")
    }

    // MARK: - Request plumbing

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await request(path: path, method: "GET", query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await request(path: path, method: "POST", query: [], body: body)
    }

    func put<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await request(path: path, method: "PUT", query: [], body: body)
    }

    /// DELETE with no response body expected.
    func delete(_ path: String) async throws {
        struct Nothing: Decodable {}
        let _: Nothing = try await request(path: path, method: "DELETE", query: [], body: nil)
    }

    private func request<T: Decodable>(path: String, method: String,
                                       query: [URLQueryItem], body: Data?) async throws -> T {
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query }
        let url = comps.url!

        var attempt = 0
        var forceRefresh = false
        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            if body != nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let token = try await tokens.accessToken(for: accountId, forceRefresh: forceRefresh)
            forceRefresh = false
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299:
                // DELETE (and some modify calls) return an empty body.
                let payload = data.isEmpty ? Data("{}".utf8) : data
                return try JSONDecoder().decode(T.self, from: payload)
            case 401 where attempt <= 2:
                forceRefresh = true
            case 403, 429, 500...599:
                guard attempt <= 4 else {
                    throw MailError.http(code, String(data: data, encoding: .utf8) ?? "")
                }
                // 2/4/8/16s: a per-minute quota 403 needs the window to roll
                // over, and the old 1–8s series gave up inside it.
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
            default:
                throw MailError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
