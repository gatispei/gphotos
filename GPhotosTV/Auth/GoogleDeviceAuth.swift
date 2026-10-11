import Foundation

/// A pending device-code grant, shown to the user as a code + QR pair.
struct DeviceCodeGrant: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let interval: TimeInterval
    let expiresAt: Date
}

enum AuthError: LocalizedError {
    case notConfigured
    case denied
    case codeExpired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No OAuth client is bundled. See the README to add Config.xcconfig."
        case .denied:
            return "Access was denied on the signing-in device."
        case .codeExpired:
            return "The pairing code expired. Start again."
        case .server(let message):
            return message
        }
    }
}

/// OAuth 2.0 for TV and Limited-Input Devices.
///
/// tvOS has no in-app browser, so the device-code flow is the only practical
/// grant: the TV shows a short code, the user authorizes on a phone, and we poll.
actor GoogleDeviceAuth {
    static let shared = GoogleDeviceAuth()

    private var credentials: StoredCredentials? = TokenStore.load()
    private var refreshTask: Task<String, Error>?

    var isSignedIn: Bool { credentials != nil }
    var deviceID: String? { credentials?.deviceID }

    func setDeviceID(_ id: String) {
        guard var current = credentials else { return }
        current.deviceID = id
        credentials = current
        TokenStore.save(current)
    }

    func signOut() {
        credentials = nil
        refreshTask = nil
        TokenStore.clear()
    }

    // MARK: - Device code flow

    func requestCode() async throws -> DeviceCodeGrant {
        guard let config = OAuthConfig.current else { throw AuthError.notConfigured }
        let body = [
            "client_id": config.clientID,
            "scope": OAuthConfig.scopes.joined(separator: " "),
        ]
        let json = try await postForm(Endpoints.deviceCode, fields: body)

        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String else {
            throw AuthError.server("Malformed device-code response.")
        }
        let url = (json["verification_url"] as? String)
            ?? (json["verification_uri"] as? String)
            ?? "https://www.google.com/device"
        let interval = (json["interval"] as? Double) ?? 5
        let expiresIn = (json["expires_in"] as? Double) ?? 1800

        return DeviceCodeGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            interval: interval,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Polls until the user authorizes, honouring Google's `slow_down` backoff.
    func poll(for grant: DeviceCodeGrant) async throws {
        guard let config = OAuthConfig.current else { throw AuthError.notConfigured }
        var delay = grant.interval

        while true {
            if Date() > grant.expiresAt { throw AuthError.codeExpired }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            let json = try await postForm(Endpoints.token, fields: [
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "device_code": grant.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            if let error = json["error"] as? String {
                switch error {
                case "authorization_pending": continue
                case "slow_down": delay += 5
                case "access_denied": throw AuthError.denied
                case "expired_token": throw AuthError.codeExpired
                default: throw AuthError.server(error)
                }
                continue
            }

            guard let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String else {
                throw AuthError.server("Token response missing credentials.")
            }
            let lifetime = (json["expires_in"] as? Double) ?? 3600
            let stored = StoredCredentials(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: Date().addingTimeInterval(lifetime),
                deviceID: credentials?.deviceID
            )
            credentials = stored
            TokenStore.save(stored)
            return
        }
    }

    // MARK: - Token access

    /// A valid bearer token, refreshing when needed. Concurrent callers share one
    /// refresh so a burst of image loads cannot stampede the token endpoint.
    func validAccessToken() async throws -> String {
        guard let current = credentials else { throw AuthError.denied }
        if !current.isExpired { return current.accessToken }

        if let existing = refreshTask { return try await existing.value }

        let task = Task<String, Error> { try await performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: StoredCredentials) async throws -> String {
        guard let config = OAuthConfig.current else { throw AuthError.notConfigured }
        let json = try await postForm(Endpoints.token, fields: [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ])

        if let error = json["error"] as? String {
            // A revoked or expired refresh token is unrecoverable: force re-pairing.
            signOut()
            throw AuthError.server("Session expired (\(error)). Sign in again.")
        }
        guard let access = json["access_token"] as? String else {
            throw AuthError.server("Refresh response missing access token.")
        }
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        var updated = current
        updated.accessToken = access
        updated.expiresAt = Date().addingTimeInterval(lifetime)
        // Google only returns a new refresh token when it rotates one.
        if let rotated = json["refresh_token"] as? String { updated.refreshToken = rotated }
        credentials = updated
        TokenStore.save(updated)
        return access
    }

    // MARK: - Transport

    private func postForm(_ url: URL, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.server("Unreadable response from \(url.host ?? "server").")
        }
        return json
    }
}
