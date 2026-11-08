import SwiftUI
import SwiftDraw

#if os(macOS)
import AppKit
#endif

struct RemoteImageView: View {
    let url: URL?

    @State private var image: PlatformImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else { image = nil; isLoading = false; return }

        if let cached = await ImageCache.shared.image(for: url) {
            image = cached; isLoading = false; return
        }

        isLoading = true

        do {
            let (data, response) = try await AuthorizedFetcher.shared.data(from: url)
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isSVG = contentType.contains("svg") || url.pathExtension.lowercased() == "svg"

            if isSVG, let rasterized = SVGRasterizer.image(from: data) {
                await ImageCache.shared.store(rasterized, for: url)
                image = rasterized
            } else if !isSVG, let img = PlatformImage(data: data) {
                await ImageCache.shared.store(img, for: url)
                image = img
            } else {
                image = nil
            }
        } catch {
            image = nil
        }
        isLoading = false
    }
}

enum SVGRasterizer {
    static func image(from data: Data, maxSide: CGFloat = 512) -> PlatformImage? {
        guard let svg = SVG(data: data), svg.size.width > 0, svg.size.height > 0 else { return nil }
        let scale = min(maxSide / svg.size.width, maxSide / svg.size.height)
        let size = CGSize(width: (svg.size.width * scale).rounded(), height: (svg.size.height * scale).rounded())
        #if os(macOS)
        return svg.rasterize(with: size, scale: 1)
        #else
        return svg.rasterize(size: size)
        #endif
    }
}
