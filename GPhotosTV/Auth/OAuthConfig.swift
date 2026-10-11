import Foundation

/// OAuth client credentials for the Google Photos Ambient API.
///
/// Values come from `Config.xcconfig` (untracked) via Info.plist so that
/// credentials never land in version control. See `Config.example.xcconfig`.
struct OAuthConfig {
    let clientID: String
    let clientSecret: String

    /// Scope required by the Ambient API, plus `profile` so we can greet the user.
    static let scopes = [
        "https://www.googleapis.com/auth/photosambient.mediaitems",
        "profile",
    ]

    static var isConfigured: Bool { current != nil }

    /// Returns nil when the app was built without credentials, which lets the UI
    /// show setup instructions instead of failing an opaque network call.
    static let current: OAuthConfig? = {
        func value(_ key: String) -> String? {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unsubstituted xcconfig variable arrives as the literal "$(NAME)".
            guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
            return trimmed
        }
        guard let id = value("GPTVClientID"), let secret = value("GPTVClientSecret") else { return nil }
        return OAuthConfig(clientID: id, clientSecret: secret)
    }()
}

enum Endpoints {
    static let deviceCode = URL(string: "https://oauth2.googleapis.com/device/code")!
    static let token = URL(string: "https://oauth2.googleapis.com/token")!
    static let ambient = URL(string: "https://photosambient.googleapis.com/v1")!
}
