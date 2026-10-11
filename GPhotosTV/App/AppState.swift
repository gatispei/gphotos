import Foundation
import Observation
import UIKit

enum AppPhase: Equatable {
    case loading
    /// Built without OAuth credentials — show setup instructions.
    case unconfigured
    case signedOut
    case pairing(DeviceCodeGrant)
    /// Signed in, but the user has not picked which albums this TV may show.
    case awaitingMediaSources(AmbientDevice)
    case browsing
    case failed(String)
}

@MainActor
@Observable
final class AppState {
    var phase: AppPhase = .loading
    var sourceKind: SourceKind = .ambient
    var localArchiveHost: String
    var device: AmbientDevice?
    var library = LibraryStore()
    var quotaRemaining: Int = QuotaTracker.dailyLimit

    private let defaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?

    init() {
        localArchiveHost = defaults.string(forKey: "localArchiveHost") ?? ""
        if let raw = defaults.string(forKey: "sourceKind"), let kind = SourceKind(rawValue: raw) {
            sourceKind = kind
        }
    }

    var activeSource: PhotoSource? { library.source }

    // MARK: - Lifecycle

    func start() async {
        switch sourceKind {
        case .localArchive:
            await activateLocalArchive()
        case .ambient:
            await activateAmbient()
        }
    }

    func select(_ kind: SourceKind) async {
        guard kind != sourceKind else { return }
        sourceKind = kind
        defaults.set(kind.rawValue, forKey: "sourceKind")
        library.reset()
        phase = .loading
        await start()
    }

    func setLocalArchiveHost(_ host: String) async {
        localArchiveHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(localArchiveHost, forKey: "localArchiveHost")
        if sourceKind == .localArchive { await activateLocalArchive() }
    }

    // MARK: - Local archive

    private func activateLocalArchive() async {
        guard let url = normalizedArchiveURL() else {
            phase = .failed("Set the address of your Takeout server in Settings, for example http://mac-mini.local:8099")
            return
        }
        phase = .loading
        let source = LocalArchiveSource(baseURL: url)
        do {
            try await library.activate(source: source)
            phase = .browsing
        } catch {
            phase = .failed("Could not reach the archive server at \(url.absoluteString). \(error.localizedDescription)")
        }
    }

    private func normalizedArchiveURL() -> URL? {
        var text = localArchiveHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text) else { return nil }
        if components.port == nil { components.port = 8099 }
        return components.url
    }

    // MARK: - Ambient

    private func activateAmbient() async {
        guard OAuthConfig.isConfigured else {
            phase = .unconfigured
            return
        }
        guard await GoogleDeviceAuth.shared.isSignedIn else {
            phase = .signedOut
            return
        }
        phase = .loading
        await refreshQuota()

        do {
            let name = UIDevice.current.name
            let device = try await AmbientAPI.shared.ensureDevice(displayName: "Apple TV — \(name)")
            self.device = device

            if device.mediaSourcesSet == true {
                try await library.activate(source: AmbientSource(device: device))
                phase = .browsing
            } else {
                phase = .awaitingMediaSources(device)
                startPolling(device)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await refreshQuota()
    }

    /// Watches for the user finishing album selection on their phone.
    private func startPolling(_ device: AmbientDevice) {
        pollTask?.cancel()
        let interval = device.pollingConfig?.seconds ?? 10
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                guard let refreshed = try? await AmbientAPI.shared.getDevice(device.id) else { continue }
                if refreshed.mediaSourcesSet == true {
                    self.device = refreshed
                    try? await self.library.activate(source: AmbientSource(device: refreshed))
                    self.phase = .browsing
                    await self.refreshQuota()
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Sign in / out

    func beginPairing() async {
        do {
            let grant = try await GoogleDeviceAuth.shared.requestCode()
            phase = .pairing(grant)
            try await GoogleDeviceAuth.shared.poll(for: grant)
            await activateAmbient()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        stopPolling()
        if let id = device?.id {
            // Best effort: keeps the user's 100-device budget tidy.
            try? await AmbientAPI.shared.deleteDevice(id)
        }
        await GoogleDeviceAuth.shared.signOut()
        device = nil
        library.reset()
        MediaCache.shared.purge()
        phase = .signedOut
    }

    func refreshQuota() async {
        quotaRemaining = await QuotaTracker.shared.remaining
    }
}

/// Holds the current source's collections and the paged item list.
@MainActor
@Observable
final class LibraryStore {
    private(set) var source: PhotoSource?
    private(set) var collections: [MediaCollection] = []
    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    var selected: MediaCollection?

    private var nextPageToken: String?
    private var fetchedAt: Date?
    private var reachedEnd = false

    func reset() {
        source = nil
        collections = []
        items = []
        selected = nil
        nextPageToken = nil
        fetchedAt = nil
        reachedEnd = false
        loadError = nil
    }

    func activate(source: PhotoSource) async throws {
        self.source = source
        collections = try await source.collections()
        selected = nil
        try await reload()
    }

    func select(_ collection: MediaCollection?) async {
        guard selected?.id != collection?.id else { return }
        selected = collection
        try? await reload()
    }

    func reload() async throws {
        guard let source else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        items = []
        nextPageToken = nil
        reachedEnd = false

        let page = try await source.page(collection: selected, pageToken: nil, pageSize: 100)
        items = page.items
        nextPageToken = page.nextPageToken
        reachedEnd = page.nextPageToken == nil
        fetchedAt = Date()
    }

    func loadMoreIfNeeded(currentItem: MediaItem) async {
        guard !isLoading, !reachedEnd, let source, let token = nextPageToken else { return }
        // Trigger when the user focuses near the tail of what we have.
        guard let index = items.firstIndex(of: currentItem), index >= items.count - 12 else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await source.page(collection: selected, pageToken: token, pageSize: 100)
            // Guard against duplicate ids, which would break Identifiable diffing.
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
        } catch {
            loadError = error.localizedDescription
            reachedEnd = true // stop hammering a failing endpoint
        }
    }

    /// Google's signed URLs expire after an hour; refetch before they do.
    var needsFreshURLs: Bool {
        guard source?.kind == .ambient, let fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) > AmbientSource.baseURLLifetime
    }

    func refreshIfStale() async {
        guard needsFreshURLs else { return }
        try? await reload()
    }
}
