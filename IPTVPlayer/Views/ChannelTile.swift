import SwiftUI

struct ChannelTile: View {
    let channel: Channel
    #if os(tvOS)
    /// True while the grid is previewing this channel behind the tiles: the
    /// wash darkens so the focused tile keeps its logo and title readable.
    var isPreviewing = false
    #endif

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        VStack(spacing: 8) {
            #if os(tvOS)
            RemoteImageView(url: channel.logoURL)
                .frame(width: 120, height: 120)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            #else
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .overlay {
                    RemoteImageView(url: channel.logoURL)
                        .padding(8)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            #endif

            Text(channel.name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        #if os(tvOS)
        .shadow(color: .black.opacity(isPreviewing ? 0.9 : 0), radius: 8)
        .scaleEffect(isFocused ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        #endif
    }
}
