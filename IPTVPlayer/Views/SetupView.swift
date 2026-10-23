import SwiftUI

/// First run: no server is built in. The playlist URL is typed in here, or
/// filled in by a Zenith server found on the local network (discovery
/// applies it without asking while nothing is configured).
struct SetupView: View {
    var settingsStore: SettingsStore

    @State private var urlText = ""

    private var trimmed: String { urlText.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool {
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Welcome to Zenith Player")
                .font(.title2)
            Text("Enter the address of an M3U playlist of MPEG-TS streams. A Zenith server on this network is found automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("http://server.local/playlist.m3u", text: $urlText)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                #endif
            Button("Load Playlist") {
                settingsStore.setPlaylist(trimmed)
            }
            .disabled(!isValid)
        }
        .frame(maxWidth: 900)
        .padding(48)
    }
}
