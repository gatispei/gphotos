import AVKit
import SwiftUI

/// Full-screen viewer with remote-driven paging.
struct PhotoDetailView: View {
    let items: [MediaItem]
    let startAt: MediaItem
    let source: PhotoSource

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var showInfo = true
    @State private var player: AVPlayer?
    @State private var infoHideTask: Task<Void, Never>?

    private var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let current {
                if current.isVideo, let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    RemoteImage(item: current, source: source, dimension: 1920, crop: false)
                        .ignoresSafeArea()
                        .id(current.id)
                }
            }

            if showInfo, let current {
                infoOverlay(current)
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            case .up, .down: revealInfo()
            default: break
            }
        }
        .onExitCommand { dismiss() }
        .onAppear {
            index = items.firstIndex(of: startAt) ?? 0
            revealInfo()
            Task { await prepareVideoIfNeeded() }
        }
        .onDisappear {
            infoHideTask?.cancel()
            player?.pause()
        }
    }

    private func infoOverlay(_ item: MediaItem) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let date = item.createdAt {
                        Text(date.formatted(date: .long, time: .shortened))
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    HStack(spacing: 16) {
                        if let name = item.filename {
                            Text(name)
                        }
                        if let w = item.width, let h = item.height {
                            Text("\(w) × \(h)")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(index + 1) of \(items.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(50)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        index = next
        player?.pause()
        player = nil
        revealInfo()
        Task { await prepareVideoIfNeeded() }
    }

    private func revealInfo() {
        infoHideTask?.cancel()
        withAnimation { showInfo = true }
        infoHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showInfo = false }
        }
    }

    private func prepareVideoIfNeeded() async {
        guard let current, current.isVideo else { return }
        guard let request = try? await source.videoRequest(for: current), let url = request.url else { return }

        // AVPlayer cannot see URLSession headers, so pass the bearer token to the asset.
        var options: [String: Any] = [:]
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = newPlayer
        newPlayer.play()
    }
}
