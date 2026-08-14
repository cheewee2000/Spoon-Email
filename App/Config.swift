import Foundation

enum Config {
    /// Compiled-in fallback for the Google OAuth client ID (type "iOS",
    /// bundle id com.cwandt.spoon). Public builds ship this empty — each
    /// user pastes their own client ID into the in-app setup sheet, which
    /// stores it in UserDefaults. See README "One-time Google Cloud setup".
    static let defaultGoogleClientID = ""

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

    static func setGoogleClientID(_ id: String) {
        UserDefaults.standard.set(
            id.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey)
    }
}
