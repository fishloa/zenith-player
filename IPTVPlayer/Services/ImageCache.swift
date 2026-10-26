#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CryptoKit
import SVGKit

actor ImageCache {
    static let shared: ImageCache = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return ImageCache(directory: base.appendingPathComponent("logos", isDirectory: true))
    }()

    private let directory: URL
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

    init(directory: URL) {
        self.directory = directory
    }

    func image(for url: URL) -> PlatformImage? {
        if let cached = rasterCache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        let fileURL = fileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let mdate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mdate) > 7 * 24 * 60 * 60 {
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL),
              let image = platformImage(from: data) else { return nil }
        rasterCache.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }

    func store(_ image: PlatformImage, for url: URL) {
        #if os(macOS)
        let cost = Int(image.size.width) * Int(image.size.height) * 4
        #else
        let cost = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        #endif
        rasterCache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = fileURL(for: url)
        if let data = pngData(of: image) {
            try? data.write(to: fileURL)
        }
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
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Disk helpers

    private func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(hash + ".png")
    }

    private func pngData(of image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }

    private func platformImage(from data: Data) -> PlatformImage? {
        #if os(macOS)
        return NSImage(data: data)
        #else
        return UIImage(data: data)
        #endif
    }
}