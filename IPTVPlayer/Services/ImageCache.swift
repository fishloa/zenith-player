#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SVGKit

actor ImageCache {
    static let shared = ImageCache()

    private let rasterCache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 200
        c.totalCostLimit = 50 * 1024 * 1024
        return c
    }()

    private let svgCache: NSCache<NSString, SVGKImage> = {
        let c = NSCache<NSString, SVGKImage>()
        c.countLimit = 100
        return c
    }()

    private init() {}

    func image(for url: URL) -> PlatformImage? {
        rasterCache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: PlatformImage, for url: URL) {
        #if os(macOS)
        let cost = Int(image.size.width) * Int(image.size.height) * 4
        #else
        let cost = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        #endif
        rasterCache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    func svgImage(for url: URL) -> SVGKImage? {
        svgCache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ svg: SVGKImage, for url: URL) {
        svgCache.setObject(svg, forKey: url.absoluteString as NSString)
    }

    func clear() {
        rasterCache.removeAllObjects()
        svgCache.removeAllObjects()
    }
}
