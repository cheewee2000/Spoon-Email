import Foundation
import Security

enum KeychainStore {
    private static let service = "com.cwandt.spoon.tokens"

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { a, _ in a } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MailError.keychain(status)
        }
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum MailError: Error, LocalizedError {
    case keychain(OSStatus)
    case oauthFailed(String)
    case notConfigured
    case http(Int, String)
    case noRefreshToken
    /// Google's token endpoint refused the refresh token (invalid_grant —
    /// revoked, password changed, or expired under a Testing-mode client).
    /// Only a fresh interactive sign-in clears it.
    case authRevoked(String)

    /// True when the account can't be used again without the user signing
    /// in — as opposed to a transient network/server error.
    public var isAuthFailure: Bool {
        switch self {
        case .authRevoked, .noRefreshToken: return true
        case .http(401, _): return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .keychain(let s): return "Keychain error (\(s))"
        case .oauthFailed(let m): return "Sign-in failed: \(m)"
        case .notConfigured: return "Add your Google OAuth client ID first — click Add Account and follow the setup steps."
        case .http(let code, let body):
            if body.contains("rateLimitExceeded") { return "Gmail rate limit hit — wait a minute and try again." }
            return "Gmail API error \(code): \(body)"
        case .authRevoked(let m): return "Google signed this account out (\(m)) — reconnect it to keep syncing."
        case .noRefreshToken: return "Account needs to be re-added (no refresh token)."
        }
    }
}
