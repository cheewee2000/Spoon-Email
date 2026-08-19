import Foundation
import CryptoKit
import AuthenticationServices
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct GoogleOAuthConfig: Sendable {
    private let provider: @Sendable () -> String

    /// Resolved on every read, so a client ID saved in-app takes effect
    /// immediately for the stores that captured this config at startup.
    public var clientID: String { provider() }

    public init(clientID: String) {
        self.provider = { clientID }
    }

    public init(clientIDProvider: @escaping @Sendable () -> String) {
        self.provider = clientIDProvider
    }

    public var isConfigured: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.hasPrefix("PASTE")
    }

    /// Reversed-client-ID custom URL scheme, e.g. com.googleusercontent.apps.1234-abc
    public var redirectScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps." + prefix
    }

    public var redirectURI: String { redirectScheme + ":/oauth2redirect" }

    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
    ]
}

public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

/// Runs the interactive OAuth 2 + PKCE flow in ASWebAuthenticationSession
/// and exchanges/refreshes tokens. No Google SDK.
public enum GoogleOAuth {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    @MainActor
    public static func signIn(config: GoogleOAuthConfig, loginHint: String? = nil) async throws -> OAuthTokens {
        guard config.isConfigured else { throw MailError.notConfigured }
        let verifier = randomURLSafe(48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Always show the account chooser so a second account can be added
            .init(name: "prompt", value: "select_account"),
        ]
        // Reconnecting: preselect the address that needs it.
        if let loginHint { comps.queryItems?.append(.init(name: "login_hint", value: loginHint)) }

        let callbackURL = try await runSession(url: comps.url!, scheme: config.redirectScheme)
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            throw MailError.oauthFailed(err)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw MailError.oauthFailed("missing authorization code")
        }

        return try await exchange(form: [
            "code": code,
            "client_id": config.clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ], existingRefreshToken: nil)
    }

    public static func refresh(tokens: OAuthTokens, config: GoogleOAuthConfig) async throws -> OAuthTokens {
        guard !tokens.refreshToken.isEmpty else { throw MailError.noRefreshToken }
        do {
            return try await exchange(form: [
                "client_id": config.clientID,
                "refresh_token": tokens.refreshToken,
                "grant_type": "refresh_token",
            ], existingRefreshToken: tokens.refreshToken)
        } catch MailError.http(let code, let body) where (400...499).contains(code) {
            // A 4xx from the token endpoint means the grant itself is dead —
            // retrying every sync pass will never fix it.
            let reason = body.range(of: #""error"\s*:\s*"([^"]+)""#, options: .regularExpression)
                .map { String(body[$0]).components(separatedBy: "\"").dropLast().last ?? body } ?? "HTTP \(code)"
            throw MailError.authRevoked(reason)
        }
    }

    // MARK: - Internals

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private static func exchange(form: [String: String], existingRefreshToken: String?) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw MailError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let tr = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: tr.access_token,
            refreshToken: tr.refresh_token ?? existingRefreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(tr.expires_in))
        )
    }

    @MainActor
    private static func runSession(url: URL, scheme: String) async throws -> URL {
        let presenter = WebAuthPresenter()
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                withExtendedLifetime(presenter) {}
                if let callbackURL {
                    cont.resume(returning: callbackURL)
                } else {
                    cont.resume(throwing: MailError.oauthFailed(error?.localizedDescription ?? "cancelled"))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ??
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
