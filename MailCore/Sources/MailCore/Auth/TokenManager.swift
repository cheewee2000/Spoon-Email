import Foundation

/// Per-account token cache + refresh, serialized so concurrent API calls
/// never trigger duplicate refreshes.
public actor TokenManager {
    private let config: GoogleOAuthConfig
    private var cache: [String: OAuthTokens] = [:]
    private var refreshTasks: [String: Task<OAuthTokens, Error>] = [:]

    public init(config: GoogleOAuthConfig) {
        self.config = config
    }

    public func store(_ tokens: OAuthTokens, accountId: String) throws {
        cache[accountId] = tokens
        try KeychainStore.save(JSONEncoder().encode(tokens), account: accountId)
    }

    public func remove(accountId: String) {
        cache[accountId] = nil
        refreshTasks[accountId] = nil
        KeychainStore.delete(account: accountId)
    }

    public func accessToken(for accountId: String, forceRefresh: Bool = false) async throws -> String {
        var tokens = cache[accountId]
        if tokens == nil, let data = KeychainStore.load(account: accountId) {
            tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data)
            cache[accountId] = tokens
        }
        guard var t = tokens else { throw MailError.noRefreshToken }

        if forceRefresh || t.isExpiringSoon {
            if let running = refreshTasks[accountId] {
                t = try await running.value
            } else {
                let task = Task { [config] in
                    try await GoogleOAuth.refresh(tokens: t, config: config)
                }
                refreshTasks[accountId] = task
                defer { refreshTasks[accountId] = nil }
                t = try await task.value
                try store(t, accountId: accountId)
            }
        }
        return t.accessToken
    }
}
