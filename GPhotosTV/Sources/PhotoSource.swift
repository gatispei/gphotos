import Foundation

// MARK: - Models

/// A photo or video, normalised across the Ambient API and the local archive.
struct MediaItem: Identifiable, Hashable {
    let id: String
    let createdAt: Date?
    let filename: String?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let isVideo: Bool
    /// Ambient: a Google `baseUrl` needing size suffixes and a bearer token.
    /// Local archive: a ready-to-use absolute URL.
    let baseURL: String
    /// Videos are only playable once Google finishes transcoding.
    let videoReady: Bool

    var aspectRatio: Double {
        guard let w = width, let h = height, w > 0, h > 0 else { return 1 }
        return Double(w) / Double(h)
    }
}

/// A browsable grouping: an Ambient media source, or a local album/year.
struct MediaCollection: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int?
}

struct MediaPage {
    let items: [MediaItem]
    let nextPageToken: String?
}

enum SourceKind: String, Codable, CaseIterable {
    case ambient
    case localArchive

    var title: String {
        switch self {
        case .ambient: return "Google Photos (Ambient)"
        case .localArchive: return "Local Takeout Archive"
        }
    }
}

// MARK: - Protocol

/// A backend the browser UI can page through.
protocol PhotoSource: Sendable {
    var kind: SourceKind { get }

    /// Collections to offer in the sidebar. May be empty for a flat source.
    func collections() async throws -> [MediaCollection]

    /// One page of items. `collection == nil` means the default/curated feed.
    func page(collection: MediaCollection?, pageToken: String?, pageSize: Int) async throws -> MediaPage

    /// A fully-formed request for the bytes of `item` at roughly `maxDimension`
    /// points, including any auth headers the backend needs.
    func request(for item: MediaItem, maxDimension: Int, crop: Bool) async throws -> URLRequest

    /// A request for playable video bytes, if the source supports video.
    func videoRequest(for item: MediaItem) async throws -> URLRequest?
}

// MARK: - Shared decoding

/// Google returns `mediaFile` in the same shape for the Ambient and Picker APIs.
/// Decoding is deliberately lenient: unknown or missing metadata degrades to nil
/// rather than failing a whole page.
struct GoogleMediaFile: Decodable {
    struct Metadata: Decodable {
        struct VideoMetadata: Decodable { let processingStatus: String? }
        let width: IntOrString?
        let height: IntOrString?
        let videoMetadata: VideoMetadata?
    }
    let baseUrl: String
    let mimeType: String?
    let filename: String?
    let mediaFileMetadata: Metadata?
}

struct GoogleMediaItem: Decodable {
    let id: String
    let creationTime: String?
    let createTime: String?
    let type: String?
    let mediaFile: GoogleMediaFile

    func normalized() -> MediaItem {
        let mime = mediaFile.mimeType ?? ""
        let isVideo = type?.uppercased() == "VIDEO"
            || mime.hasPrefix("video/")
            || mediaFile.mediaFileMetadata?.videoMetadata != nil
        let status = mediaFile.mediaFileMetadata?.videoMetadata?.processingStatus
        return MediaItem(
            id: id,
            createdAt: Self.parseTimestamp(creationTime ?? createTime),
            filename: mediaFile.filename,
            mimeType: mediaFile.mimeType,
            width: mediaFile.mediaFileMetadata?.width?.value,
            height: mediaFile.mediaFileMetadata?.height?.value,
            isVideo: isVideo,
            baseURL: mediaFile.baseUrl,
            // Treat an absent status as ready; only an explicit non-READY blocks playback.
            videoReady: !isVideo || status == nil || status == "READY"
        )
    }

    private static let formatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

/// Protobuf JSON encodes int64 as a string but int32 as a number; accept either.
struct IntOrString: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self) {
            value = Int(string)
        } else {
            value = nil
        }
    }
}
