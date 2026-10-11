import Foundation
import Security

/// Persisted OAuth state. `deviceID` is the Ambient API device handle, which must
/// survive relaunches or we would orphan devices against the 100-per-user limit.
struct StoredCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var deviceID: String?

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Keychain-backed credential storage.
///
/// tvOS has no persistent per-app Keychain guarantee across reinstalls, which is
/// fine: losing the token just means signing in again.
enum TokenStore {
    private static let service = "com.gphotostv.app.oauth"
    private static let account = "google-ambient"

    static func load() -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    static func save(_ credentials: StoredCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
