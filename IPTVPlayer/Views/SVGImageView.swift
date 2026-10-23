import SwiftUI
import SVGKit

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
            let contentType = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? ""
            let isSVG = contentType.contains("svg") || url.pathExtension.lowercased() == "svg"

            if isSVG, let rasterized = rasterizeSVG(data: data) {
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

    private func rasterizeSVG(data: Data) -> PlatformImage? {
        guard let svg = SVGKImage(data: data) else { return nil }
        let svgSize = svg.size ?? .zero
        guard svgSize.width > 0, svgSize.height > 0 else { return nil }

        let maxWidth: CGFloat = 512
        let scale = min(maxWidth / svgSize.width, maxWidth / svgSize.height)
        let targetSize = CGSize(width: svgSize.width * scale, height: svgSize.height * scale)
        svg.size = targetSize

        // SVGKit can crash on malformed SVG paths — wrap in ObjC exception catcher
        var result: PlatformImage?
        _ = try? ObjCExceptionCatcher.try {
            #if os(macOS)
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            if width > 0, height > 0,
               let cgContext = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
               ) {
                // CALayer.render(in:) expects a flipped (y-down) context, matching iOS's UIGraphicsImageRenderer.
                cgContext.translateBy(x: 0, y: targetSize.height)
                cgContext.scaleBy(x: 1, y: -1)
                svg.caLayerTree?.render(in: cgContext)
                if let cgImage = cgContext.makeImage() {
                    result = NSImage(cgImage: cgImage, size: targetSize)
                }
            }
            #else
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            result = renderer.image { ctx in
                svg.caLayerTree?.render(in: ctx.cgContext)
            }
            #endif
        }
        return result
    }
}
