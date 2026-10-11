import Foundation
import SwiftUI
import UIKit

enum ImageLoadError: Error {
    /// A signed Google base URL has aged out; the item list must be refetched.
    case staleURL
}

/// Fetches and decodes media bytes, collapsing duplicate in-flight requests so a
/// scrolling grid cannot issue the same download twice.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private var inFlight: [String: Task<UIImage, Error>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // we cache ourselves
        return URLSession(configuration: config)
    }()

    func image(
        for item: MediaItem,
        source: PhotoSource,
        dimension: Int,
        crop: Bool
    ) async throws -> UIImage {
        if let cached = MediaCache.shared.cachedImage(id: item.id, dimension: dimension, crop: crop) {
            return cached
        }

        let key = "\(item.id)-\(dimension)-\(crop)"
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<UIImage, Error> {
            let request = try await source.request(for: item, maxDimension: dimension, crop: crop)
            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // 403/404 on a base URL means the signature expired.
                if http.statusCode == 403 || http.statusCode == 404 { throw ImageLoadError.staleURL }
                throw AmbientError.http(http.statusCode, "Could not load media")
            }
            guard let image = UIImage(data: data) else { throw ImageLoadError.staleURL }

            MediaCache.shared.store(data, image: image, id: item.id, dimension: dimension, crop: crop)
            return image
        }

        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// Focus-aware async image tile.
struct RemoteImage: View {
    let item: MediaItem
    let source: PhotoSource
    let dimension: Int
    var crop: Bool = true

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: crop ? .fill : .fit)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .overlay {
                        if failed {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .task(id: item.id) { await load() }
    }

    private func load() async {
        // A cache hit should not flash a spinner.
        if let cached = MediaCache.shared.cachedImage(id: item.id, dimension: dimension, crop: crop) {
            image = cached
            return
        }
        do {
            image = try await ImagePipeline.shared.image(
                for: item, source: source, dimension: dimension, crop: crop
            )
            failed = false
        } catch is CancellationError {
            // View scrolled away; leave the placeholder.
        } catch {
            failed = true
        }
    }
}
