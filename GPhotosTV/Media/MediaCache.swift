import Foundation
import UIKit

/// Two-tier cache for decoded thumbnails and full-size frames.
///
/// Disk caching matters more here than in a typical app: the Ambient API allows
/// only 240 list calls per device per day, and signed `baseUrl`s expire after an
/// hour, so re-fetching bytes is expensive and sometimes impossible.
final class MediaCache: @unchecked Sendable {
    static let shared = MediaCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let io = DispatchQueue(label: "com.gphotostv.cache", qos: .utility)

    private init() {
        // Cost is in bytes; tvOS devices are memory-constrained so stay modest.
        memory.totalCostLimit = 192 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(_ id: String, _ dimension: Int, _ crop: Bool) -> String {
        // Hash the id: Google item ids contain characters that are unsafe in paths.
        "\(abs(id.hashValue))-\(dimension)\(crop ? "c" : "")"
    }

    func cachedImage(id: String, dimension: Int, crop: Bool) -> UIImage? {
        let name = key(id, dimension, crop)
        if let hit = memory.object(forKey: name as NSString) { return hit }

        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: name as NSString, cost: data.count)
        return image
    }

    func store(_ data: Data, image: UIImage, id: String, dimension: Int, crop: Bool) {
        let name = key(id, dimension, crop)
        memory.setObject(image, forKey: name as NSString, cost: data.count)
        let url = directory.appendingPathComponent(name)
        io.async { try? data.write(to: url, options: .atomic) }
    }

    /// Bytes on disk, for the Settings screen.
    func diskUsage() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func purge() {
        memory.removeAllObjects()
        io.async { [directory] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
