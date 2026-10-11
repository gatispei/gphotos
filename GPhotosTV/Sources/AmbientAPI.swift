import Foundation

struct AmbientDevice: Decodable, Equatable {
    struct MediaSource: Decodable, Equatable {
        let id: String
        let displayName: String?
    }
    struct PollingConfig: Decodable, Equatable {
        let pollInterval: String?

        /// Durations arrive as protobuf strings such as "30s".
        var seconds: TimeInterval {
            guard let raw = pollInterval, raw.hasSuffix("s"),
                  let value = Double(raw.dropLast()) else { return 10 }
            return max(5, value)
        }
    }
    let id: String
    let displayName: String?
    let mediaSources: [MediaSource]?
    let settingsUri: String?
    let pollingConfig: PollingConfig?
    let mediaSourcesSet: Bool?
}

enum AmbientError: LocalizedError {
    case quotaExhausted(used: Int, limit: Int)
    case http(Int, String)
    case deviceMissing

    var errorDescription: String? {
        switch self {
        case .quotaExhausted(let used, let limit):
            return "Daily Google Photos quota reached (\(used)/\(limit) requests). It resets at midnight UTC — cached photos are still browsable."
        case .http(let code, let message):
            return "Google Photos API error \(code): \(message)"
        case .deviceMissing:
            return "This Apple TV is not registered with Google Photos yet."
        }
    }
}

/// Tracks the Ambient API's hard ceiling of 240 requests per device per day.
///
/// Browsing a large library can exhaust that quickly, so every call is counted
/// and the UI leans on the on-disk cache once the budget is spent.
actor QuotaTracker {
    static let shared = QuotaTracker()
    static let dailyLimit = 240
    /// Leave headroom so an interactive refresh never hits a hard 429.
    private static let reserve = 15

    private let defaults = UserDefaults.standard
    private let countKey = "ambient.quota.count"
    private let dayKey = "ambient.quota.day"

    private var today: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }

    private func rolled() -> Int {
        if defaults.string(forKey: dayKey) != today {
            defaults.set(today, forKey: dayKey)
            defaults.set(0, forKey: countKey)
            return 0
        }
        return defaults.integer(forKey: countKey)
    }

    var used: Int { rolled() }
    var remaining: Int { max(0, Self.dailyLimit - rolled()) }

    /// Consumes one unit, or throws when the budget is spent.
    func consume() throws {
        let current = rolled()
        guard current < Self.dailyLimit - Self.reserve else {
            throw AmbientError.quotaExhausted(used: current, limit: Self.dailyLimit)
        }
        defaults.set(current + 1, forKey: countKey)
    }
}

/// Transport for `photosambient.googleapis.com`.
actor AmbientAPI {
    static let shared = AmbientAPI()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    // MARK: - Devices

    /// Returns the stored device, or registers a new one with Google.
    func ensureDevice(displayName: String) async throws -> AmbientDevice {
        if let existing = await GoogleDeviceAuth.shared.deviceID {
            do {
                return try await getDevice(existing)
            } catch AmbientError.http(let code, _) where code == 404 || code == 403 {
                // The user deleted the device in Google Photos; register again.
            }
        }
        return try await createDevice(displayName: displayName)
    }

    func createDevice(displayName: String) async throws -> AmbientDevice {
        var components = URLComponents(
            url: Endpoints.ambient.appendingPathComponent("devices"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "requestId", value: UUID().uuidString.lowercased())]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["displayName": displayName])

        let device: AmbientDevice = try await send(request)
        await GoogleDeviceAuth.shared.setDeviceID(device.id)
        return device
    }

    func getDevice(_ id: String) async throws -> AmbientDevice {
        let url = Endpoints.ambient.appendingPathComponent("devices/\(id)")
        return try await send(URLRequest(url: url))
    }

    func deleteDevice(_ id: String) async throws {
        var request = URLRequest(url: Endpoints.ambient.appendingPathComponent("devices/\(id)"))
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request, countsAgainstQuota: false)
    }

    // MARK: - Media items

    private struct ListResponse: Decodable {
        let mediaItems: [GoogleMediaItem]?
        let nextPageToken: String?
    }

    func listMediaItems(
        deviceID: String,
        mediaSourceID: String?,
        pageToken: String?,
        pageSize: Int
    ) async throws -> MediaPage {
        var components = URLComponents(
            url: Endpoints.ambient.appendingPathComponent("mediaItems"),
            resolvingAgainstBaseURL: false
        )!
        var query = [
            URLQueryItem(name: "deviceId", value: deviceID),
            URLQueryItem(name: "pageSize", value: String(min(max(pageSize, 1), 100))),
        ]
        if let mediaSourceID { query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceID)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = query

        let response: ListResponse = try await send(URLRequest(url: components.url!))
        return MediaPage(
            items: (response.mediaItems ?? []).map { $0.normalized() },
            nextPageToken: response.nextPageToken
        )
    }

    // MARK: - Plumbing

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendRaw(request, countsAgainstQuota: true)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendRaw(_ request: URLRequest, countsAgainstQuota: Bool) async throws -> Data {
        if countsAgainstQuota { try await QuotaTracker.shared.consume() }

        var authorized = request
        let token = try await GoogleDeviceAuth.shared.validAccessToken()
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else { return data }

        guard (200..<300).contains(http.statusCode) else {
            throw AmbientError.http(http.statusCode, Self.message(from: data))
        }
        return data
    }

    private static func message(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }
        return message
    }
}
