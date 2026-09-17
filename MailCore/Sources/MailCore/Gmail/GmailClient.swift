import Foundation

/// Thin async Gmail REST client for one account. Handles auth headers,
/// 401 → token refresh retry, and 429/5xx backoff.
public struct GmailClient: Sendable {
    public let accountId: String
    private let tokens: TokenManager
    /// Backfill/repair traffic: waits at the lower quota line so it can never
    /// crowd out a save, send or refresh.
    let background: Bool
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    public init(accountId: String, tokens: TokenManager, background: Bool = false) {
        self.accountId = accountId
        self.tokens = tokens
        self.background = background
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

        await QuotaGate.shared.acquire(cost: Self.cost(method: method, path: path),
                                       cap: background ? QuotaGate.backgroundCap : QuotaGate.cap)
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

// MARK: - Quota

/// Gmail's per-user budget is metered in "quota units" per minute (this
/// project's limit is 6000). Every request books its cost here first and
/// waits for the rolling window to drain when it would overspend. Two lines:
/// background passes stop at `backgroundCap`, so the band above it is always
/// free for interactive calls.
/// ponytail: one process's view of a per-user quota — a phone running the
/// same account spends from the same pool, which is why both caps sit well
/// under 6000.
actor QuotaGate {
    static let shared = QuotaGate()
    static let cap = 4500
    static let backgroundCap = 2000
    private let window: TimeInterval = 60
    private var spent: [(at: Date, cost: Int)] = []

    func acquire(cost: Int, cap: Int) async {
        while true {
            let now = Date()
            spent.removeAll { now.timeIntervalSince($0.at) > window }
            let total = spent.reduce(0) { $0 + $1.cost }
            if total + cost <= cap || spent.isEmpty {
                spent.append((now, cost))
                return
            }
            // Sleep until the oldest booking leaves the window, then re-check —
            // the actor is reentrant, so several waiters race fairly for it.
            let wait = max(0.5, window - now.timeIntervalSince(spent[0].at))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

extension GmailClient {
    /// Per-call cost from Gmail's usage-limits table.
    static func cost(method: String, path: String) -> Int {
        if path == "messages/send" { return 100 }
        if path.hasPrefix("threads") { return 10 }        // get, list, modify
        if path.hasPrefix("messages") { return 5 }        // get, list, attachments, trash
        if path.hasPrefix("drafts") {
            switch method {
            case "POST": return 10
            case "PUT": return 15
            case "DELETE": return 10
            default: return 5
            }
        }
        if path.hasPrefix("history") { return 2 }
        if path.hasPrefix("labels") { return method == "POST" ? 5 : 1 }
        if path == "profile" { return 1 }
        return 5
    }
}
