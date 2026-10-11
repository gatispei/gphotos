import Foundation

/// Full-library browsing backed by `tools/takeout-server`.
///
/// This is the only path to a *complete* library: a Google Takeout export is
/// indexed on a Mac and served over the LAN, with no API quota and real albums.
struct LocalArchiveSource: PhotoSource {
    let kind: SourceKind = .localArchive
    let baseURL: URL

    private struct CollectionsResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let title: String
            let count: Int?
        }
        let collections: [Entry]
    }

    private struct ItemsResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let filename: String?
            let mimeType: String?
            let width: Int?
            let height: Int?
            let createdAt: String?
            let isVideo: Bool?
            let url: String
        }
        let items: [Entry]
        let nextPageToken: String?
    }

    func collections() async throws -> [MediaCollection] {
        let response: CollectionsResponse = try await get("collections", query: [])
        return response.collections.map {
            MediaCollection(id: $0.id, title: $0.title, count: $0.count)
        }
    }

    func page(collection: MediaCollection?, pageToken: String?, pageSize: Int) async throws -> MediaPage {
        var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let collection { query.append(URLQueryItem(name: "collection", value: collection.id)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }

        let response: ItemsResponse = try await get("items", query: query)
        let items = response.items.map { entry in
            MediaItem(
                id: entry.id,
                createdAt: GoogleMediaItem.parseTimestamp(entry.createdAt),
                filename: entry.filename,
                mimeType: entry.mimeType,
                width: entry.width,
                height: entry.height,
                isVideo: entry.isVideo ?? (entry.mimeType?.hasPrefix("video/") ?? false),
                baseURL: absolute(entry.url).absoluteString,
                videoReady: true
            )
        }
        return MediaPage(items: items, nextPageToken: response.nextPageToken)
    }

    func request(for item: MediaItem, maxDimension: Int, crop: Bool) async throws -> URLRequest {
        var components = URLComponents(string: item.baseURL)!
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "w", value: String(maxDimension)))
        if crop { query.append(URLQueryItem(name: "crop", value: "1")) }
        components.queryItems = query
        return URLRequest(url: components.url!)
    }

    func videoRequest(for item: MediaItem) async throws -> URLRequest? {
        guard item.isVideo else { return nil }
        // The server streams the original file with range support.
        return URLRequest(url: URL(string: item.baseURL)!)
    }

    // MARK: - Plumbing

    private func absolute(_ path: String) -> URL {
        if let url = URL(string: path), url.scheme != nil { return url }
        return baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AmbientError.http(http.statusCode, "Local archive server returned \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
