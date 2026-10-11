import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch state.phase {
            case .loading:
                ProgressView("Connecting to Google Photos…")
                    .font(.title3)

            case .unconfigured:
                MessageView(
                    icon: "key.slash",
                    title: "No Google OAuth client bundled",
                    message: """
                    Create a Google Cloud OAuth client of type “TVs and Limited Input devices”, \
                    enable the Google Photos Ambient API, then copy Config.example.xcconfig to \
                    Config.local.xcconfig with your client ID and secret and rebuild.
                    """,
                    actionTitle: "Use a local Takeout archive instead"
                ) {
                    Task { await state.select(.localArchive) }
                }

            case .signedOut:
                SignInView()

            case .pairing(let grant):
                PairingView(grant: grant)

            case .awaitingMediaSources(let device):
                SourceSetupView(device: device)

            case .browsing:
                PhotoGridView()

            case .failed(let message):
                MessageView(
                    icon: "exclamationmark.triangle",
                    title: "Something went wrong",
                    message: message,
                    actionTitle: "Try again"
                ) {
                    Task { await state.start() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Shared full-screen message layout for setup, empty and error states.
struct MessageView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: icon)
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 12)
            }
        }
        .padding(60)
    }
}
