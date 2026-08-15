import Foundation

enum Config {
    /// Compiled-in fallback for the Google OAuth client ID (type "iOS",
    /// bundle id com.cwandt.spoon): CW&T's own client. Its consent screen is
    /// in Testing mode, so only addresses on our test-user list can sign in
    /// with it; anyone else pastes their own client ID into the setup sheet
    /// (Add Account… → right-click / long-press → Use Your Own Google Client
    /// ID…), which stores it in UserDefaults and overrides this. A native
    /// client ID is not a secret — PKCE, no client secret — so it's fine
    /// in a public repo. See README "Getting started".
    static let defaultGoogleClientID = "840573971970-f1em7jc7gkh3rkkd2puv388eu48plj91.apps.googleusercontent.com"

    private static let clientIDKey = "googleClientID"

    /// The active client ID: the one the user saved in-app, else the
    /// compiled-in fallback.
    static var googleClientID: String {
        if let saved = UserDefaults.standard.string(forKey: clientIDKey),
           !saved.isEmpty {
            return saved
        }
        return defaultGoogleClientID
    }

    static var isConfigured: Bool {
        googleClientID.hasSuffix(".apps.googleusercontent.com")
    }

    /// True when the user has stored their own client ID over the default.
    static var usesCustomClientID: Bool {
        let saved = UserDefaults.standard.string(forKey: clientIDKey) ?? ""
        return !saved.isEmpty && saved != defaultGoogleClientID
    }

    static func setGoogleClientID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultGoogleClientID {
            UserDefaults.standard.removeObject(forKey: clientIDKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: clientIDKey)
        }
    }
}
