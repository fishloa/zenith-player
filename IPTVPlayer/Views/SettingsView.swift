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
                        let url = urlText.trimmingCharacters(in: .whitespaces)
                        // A changed URL reloads through the root view's onChange.
                        if url == settingsStore.playlistURL { onSave() } else { settingsStore.playlistURL = url }
                        dismiss()
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
