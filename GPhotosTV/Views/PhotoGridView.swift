import SwiftUI

struct PhotoGridView: View {
    @Environment(AppState.self) private var state

    @State private var presented: MediaItem?
    @State private var slideshow = false
    @State private var showSettings = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 32), count: 5)

    private var library: LibraryStore { state.library }

    var body: some View {
        VStack(spacing: 0) {
            header

            if library.collections.count > 1 {
                collectionPicker
            }

            if library.items.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .fullScreenCover(item: $presented) { item in
            if let source = library.source {
                PhotoDetailView(
                    items: library.items,
                    startAt: item,
                    source: source
                )
            }
        }
        .fullScreenCover(isPresented: $slideshow) {
            if let source = library.source {
                SlideshowView(items: library.items, source: source)
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            // Signed base URLs expire after an hour of idling on this screen.
            await library.refreshIfStale()
            openForDebugLaunchArgumentIfNeeded()
        }
    }

    /// Lets `simctl launch … -autoOpenFirst` jump straight into a screen, so the
    /// viewer and slideshow can be exercised without a paired remote.
    private func openForDebugLaunchArgumentIfNeeded() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard !library.items.isEmpty else { return }
        if arguments.contains("-autoOpenFirst"), presented == nil {
            presented = library.items.first
        } else if arguments.contains("-autoOpenSlideshow"), !slideshow {
            slideshow = true
        }
        #endif
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(library.selected?.title ?? "All Photos")
                    .font(.system(size: 52, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                slideshow = true
            } label: {
                Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(library.items.isEmpty)

            Button {
                Task {
                    try? await library.reload()
                    await state.refreshQuota()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .focusSection()
    }

    private var subtitle: String {
        var parts = ["\(library.items.count) items"]
        if state.sourceKind == .ambient {
            parts.append("\(state.quotaRemaining) API calls left today")
        } else {
            parts.append("local archive")
        }
        if library.isLoading { parts.append("loading…") }
        return parts.joined(separator: " · ")
    }

    private var collectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                chip(title: "All", collection: nil)
                ForEach(library.collections) { collection in
                    chip(title: collection.title, collection: collection)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 12)
        }
        .focusSection()
    }

    private func chip(title: String, collection: MediaCollection?) -> some View {
        let isSelected = library.selected?.id == collection?.id
        return Button {
            Task { await library.select(collection) }
        } label: {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 10)
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
            in: Capsule()
        )
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 32) {
                ForEach(library.items) { item in
                    Button {
                        presented = item
                    } label: {
                        tile(item)
                    }
                    .buttonStyle(.card)
                    .task { await library.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)

            if library.isLoading {
                ProgressView().padding(.bottom, 40)
            }
            if let error = library.loadError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 80)
                    .padding(.bottom, 40)
            }
        }
    }

    private func tile(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let source = library.source {
                RemoteImage(item: item, source: source, dimension: 480)
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .padding(12)
                    .shadow(radius: 6)
            }
        }
        .frame(height: 220)
        .clipped()
    }

    private var emptyState: some View {
        MessageView(
            icon: "photo.on.rectangle.angled",
            title: library.isLoading ? "Loading your photos…" : "Nothing to show yet",
            message: state.sourceKind == .ambient
                ? "Google only shares the albums you assign to this TV. Open Settings to change your selection in Google Photos."
                : "The archive server returned no items. Check that it is pointed at an unzipped Takeout export.",
            actionTitle: "Open Settings"
        ) {
            showSettings = true
        }
        .frame(maxHeight: .infinity)
    }
}

/// `fullScreenCover(item:)` needs an Identifiable binding; MediaItem already is.
extension MediaItem {
    var identity: String { id }
}
