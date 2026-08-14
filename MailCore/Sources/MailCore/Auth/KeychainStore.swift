import Foundation
import Security

enum KeychainStore {
    private static let service = "com.cwandt.spoon.tokens"
    /// Tokens saved before the app was renamed from SuperDuperHuman.
    private static let legacyService = "com.cwandt.superduperhuman.tokens"

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
        if let data = load(account: account, service: service) { return data }
        // One-time migration: re-home tokens from the pre-rename service.
        guard let data = load(account: account, service: legacyService) else { return nil }
        try? save(data, account: account)
        return data
    }

    private static func load(account: String, service: String) -> Data? {
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

    public var errorDescription: String? {
        switch self {
        case .keychain(let s): return "Keychain error (\(s))"
        case .oauthFailed(let m): return "Sign-in failed: \(m)"
        case .notConfigured: return "Paste your Google OAuth client ID into App/Config.swift first (see README)."
        case .http(let code, let body): return "Gmail API error \(code): \(body)"
        case .noRefreshToken: return "Account needs to be re-added (no refresh token)."
        }
    }
}
