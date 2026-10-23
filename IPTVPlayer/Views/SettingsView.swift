import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var settingsStore: SettingsStore
    var onSave: () -> Void

    @State private var urlText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist Server") {
                    TextField("Playlist URL", text: $urlText)
                        .autocorrectionDisabled()

                    Button("Load Playlist") {
                        if !settingsStore.setPlaylist(urlText) { onSave() }
                        dismiss()
                    }
                }
                if let origin = settingsStore.playlistOrigin, settingsStore.credentials.credential(for: origin) != nil {
                    Section {
                        Button("Sign Out", role: .destructive) {
                            settingsStore.credentials.set(nil, for: origin)
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            urlText = settingsStore.playlistURL
        }
    }
}
