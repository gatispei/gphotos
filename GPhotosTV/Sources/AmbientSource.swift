import Foundation

/// Live Google Photos via the Ambient API.
///
/// Scope note: Google removed full-library read access on 2025-03-31, so this
/// source can only see the media sources (albums, people, favourites) the user
/// explicitly assigns to this device in the Google Photos app.
struct AmbientSource: PhotoSource {
    let kind: SourceKind = .ambient
    let device: AmbientDevice

    /// Google signs `baseUrl` values for 60 minutes; after that they 403.
    static let baseURLLifetime: TimeInterval = 55 * 60

    func collections() async throws -> [MediaCollection] {
        (device.mediaSources ?? []).map {
            MediaCollection(id: $0.id, title: $0.displayName ?? "Untitled source", count: nil)
        }
    }

    func page(collection: MediaCollection?, pageToken: String?, pageSize: Int) async throws -> MediaPage {
        try await AmbientAPI.shared.listMediaItems(
            deviceID: device.id,
            mediaSourceID: collection?.id,
            pageToken: pageToken,
            pageSize: pageSize
        )
    }

    func request(for item: MediaItem, maxDimension: Int, crop: Bool) async throws -> URLRequest {
        // Ambient/Picker base URLs take size suffixes: =w1920-h1080 (-c to crop).
        var suffix = "=w\(maxDimension)-h\(maxDimension)"
        if crop { suffix += "-c" }
        if item.isVideo { suffix += "-no" } // drop the baked-in play button overlay
        return try await authorized(URL(string: item.baseURL + suffix)!)
    }

    func videoRequest(for item: MediaItem) async throws -> URLRequest? {
        guard item.isVideo, item.videoReady else { return nil }
        return try await authorized(URL(string: item.baseURL + "=dv")!)
    }

    private func authorized(_ url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        let token = try await GoogleDeviceAuth.shared.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
