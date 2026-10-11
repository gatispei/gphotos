import SwiftUI

@main
struct GPhotosTVApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .task { await state.start() }
        }
    }
}
