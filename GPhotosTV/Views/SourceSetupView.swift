import SwiftUI

/// Step 2 of pairing: the user chooses which albums, people or favourites this
/// Apple TV is allowed to display. Google requires this to happen inside the
/// Google Photos app — there is no API to enumerate a library without it.
struct SourceSetupView: View {
    @Environment(AppState.self) private var state
    let device: AmbientDevice

    var body: some View {
        HStack(spacing: 80) {
            if let settings = device.settingsUri {
                QRCodeView(string: settings, size: 360)
            }

            VStack(alignment: .leading, spacing: 24) {
                Text("Choose what this TV can show")
                    .font(.system(size: 48, weight: .bold))

                Text("""
                Scan the code with your phone to open Google Photos, then pick the albums, \
                people or memories you want on this Apple TV. Select everything you would \
                like to browse — you can change it any time.
                """)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 760, alignment: .leading)

                HStack(spacing: 14) {
                    ProgressView()
                    Text("Waiting for your selection…")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                Button("Check now") {
                    Task { await state.start() }
                }
                .padding(.top, 12)
            }
        }
        .padding(80)
        .onDisappear { state.stopPolling() }
    }
}
