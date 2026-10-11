import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var cacheSize: Int64 = 0
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo source") {
                    ForEach(SourceKind.allCases, id: \.self) { kind in
                        Button {
                            Task { await state.select(kind) }
                        } label: {
                            HStack {
                                Text(kind.title)
                                Spacer()
                                if state.sourceKind == kind {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("http://mac-mini.local:8099", text: $host)
                        .onSubmit { Task { await state.setLocalArchiveHost(host) } }
                    Button("Connect to archive") {
                        Task { await state.setLocalArchiveHost(host) }
                    }
                } header: {
                    Text("Takeout archive server")
                } footer: {
                    Text("Run tools/takeout-server on your Mac to browse a complete Google Takeout export with no API quota.")
                }

                if state.sourceKind == .ambient {
                    Section {
                        LabeledContent("API calls left today", value: "\(state.quotaRemaining) of \(QuotaTracker.dailyLimit)")
                        if let device = state.device {
                            LabeledContent("Device", value: device.displayName ?? device.id)
                            if let settings = device.settingsUri {
                                NavigationLink("Change which albums are shared") {
                                    ChangeSourcesView(settingsURI: settings)
                                }
                            }
                        }
                    } header: {
                        Text("Google Photos")
                    } footer: {
                        Text("Google caps the Ambient API at \(QuotaTracker.dailyLimit) requests per device per day. Cached photos keep working after that.")
                    }
                }

                Section("Storage") {
                    LabeledContent("Cached media", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("Clear cache", role: .destructive) {
                        MediaCache.shared.purge()
                        cacheSize = 0
                    }
                }

                if state.sourceKind == .ambient {
                    Section {
                        Button("Sign out of Google", role: .destructive) {
                            confirmSignOut = true
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onExitCommand { dismiss() }
            .onAppear {
                host = state.localArchiveHost
                cacheSize = MediaCache.shared.diskUsage()
            }
            .alert("Sign out?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    Task {
                        await state.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("This removes the device from your Google Photos account and clears the local cache.")
            }
        }
    }
}

/// Re-shows the Google Photos settings QR so the user can widen the selection.
struct ChangeSourcesView: View {
    @Environment(AppState.self) private var state
    let settingsURI: String

    var body: some View {
        VStack(spacing: 32) {
            Text("Scan to change albums")
                .font(.system(size: 44, weight: .bold))

            QRCodeView(string: settingsURI, size: 320)

            Text("Pick more albums, people or memories in Google Photos, then refresh.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            Button("Refresh now") {
                Task { await state.start() }
            }
        }
        .padding(60)
    }
}
