import SwiftUI

/// Ambient slideshow with a slow Ken Burns drift — the use case the Ambient API
/// was designed for, and what an Apple TV spends most of its time doing.
struct SlideshowView: View {
    let items: [MediaItem]
    let source: PhotoSource

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var zoomedIn = false
    @State private var paused = false

    /// Seconds per slide.
    private let interval: TimeInterval = 8

    private var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let current {
                RemoteImage(item: current, source: source, dimension: 1920, crop: true)
                    .ignoresSafeArea()
                    .scaleEffect(zoomedIn ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: interval + 1), value: zoomedIn)
                    .id(current.id)
                    .transition(.opacity)
            }

            if paused {
                VStack {
                    Spacer()
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(.title2)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 28)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 60)
                }
            }
        }
        .focusable()
        .onExitCommand { dismiss() }
        .onMoveCommand { direction in
            switch direction {
            case .left: advance(-1)
            case .right: advance(1)
            default: paused.toggle()
            }
        }
        .task {
            // Skip videos: a slideshow should keep moving.
            if current?.isVideo == true { advance(1) }
            zoomedIn = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if !paused { advance(1) }
            }
        }
    }

    private func advance(_ delta: Int) {
        guard !items.isEmpty else { return }
        var next = index
        // Wrap around, stepping over videos.
        for _ in 0..<items.count {
            next = ((next + delta) % items.count + items.count) % items.count
            if !items[next].isVideo { break }
        }
        withAnimation(.easeInOut(duration: 1.0)) {
            index = next
            zoomedIn = false
        }
        // Restart the slow drift for the new slide.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            zoomedIn = true
        }
    }
}
