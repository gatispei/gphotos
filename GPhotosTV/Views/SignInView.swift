import SwiftUI

struct SignInView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "photo.stack")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("GPhotos TV")
                .font(.system(size: 64, weight: .bold))

            Text("Browse your Google Photos on the big screen.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 20) {
                Button("Sign in with Google") {
                    Task { await state.beginPairing() }
                }
                .buttonStyle(.borderedProminent)

                Button("Use a local Takeout archive") {
                    Task { await state.select(.localArchive) }
                }
            }
            .padding(.top, 20)

            Text("Signing in happens on your phone — no typing on the remote.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(60)
    }
}

/// Step 1 of pairing: the user enters a short code on a phone or laptop.
struct PairingView: View {
    let grant: DeviceCodeGrant

    var body: some View {
        HStack(spacing: 80) {
            QRCodeView(string: grant.verificationURL, size: 360)

            VStack(alignment: .leading, spacing: 28) {
                Text("Sign in on your phone")
                    .font(.system(size: 52, weight: .bold))

                stepRow(number: 1, text: "Scan the code, or visit \(displayURL)")
                stepRow(number: 2, text: "Enter this code:")

                Text(grant.userCode)
                    .font(.system(size: 76, weight: .heavy, design: .monospaced))
                    .kerning(8)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 20)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 14) {
                    ProgressView()
                    Text("Waiting for approval…")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .padding(80)
    }

    private var displayURL: String {
        grant.verificationURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.tint, in: Circle())
            Text(text)
                .font(.title3)
        }
    }
}
