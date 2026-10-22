import AVFoundation
#if os(tvOS)
import AVKit   // UIWindow.avDisplayManager
#endif
import SwiftUI
import ZenithMedia

#if os(macOS)
import AppKit

/// Hosts the player's AVSampleBufferDisplayLayer (macOS).
struct PlayerLayerView: NSViewRepresentable {
    let renderer: Renderer
    var frameRate: Double? = nil   // display-mode matching is tvOS-only

    final class LayerHost: NSView {
        let displayLayer: AVSampleBufferDisplayLayer
        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(displayLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layout() {
            super.layout()
            displayLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> LayerHost { LayerHost(displayLayer: renderer.displayLayer) }
    func updateNSView(_ nsView: LayerHost, context: Context) {}
}
#else
import UIKit

/// Hosts the player's AVSampleBufferDisplayLayer (tvOS, iPadOS).
/// On tvOS it also asks for a display mode matching the video's frame rate
/// (European TV is 50 Hz; shown at 60 Hz every fifth frame repeats, which
/// stutters on motion). tvOS applies it when Match Frame Rate is on.
struct PlayerLayerView: UIViewRepresentable {
    let renderer: Renderer
    var frameRate: Double? = nil
    /// tvOS display-mode matching (a refresh-rate switch that blanks the
    /// screen for about a second) is for full screen only, never the
    /// channel-grid preview.
    var matchesDisplayMode: Bool = true
    /// Whether this view shows the video now. The grid preview and the
    /// full-screen player share one display layer; only the one on screen
    /// (full screen, or the uncovered grid) holds it.
    var claimsLayer: Bool = true

    final class LayerHost: UIView {
        let displayLayer: AVSampleBufferDisplayLayer
        var claimsLayer = true
        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            backgroundColor = .black
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layer.addSublayer(displayLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            adoptLayer()
            displayLayer.frame = bounds
        }
        /// One display layer can sit in only one host: the grid preview and the
        /// full-screen player share it, so whichever is on screen takes it back.
        func adoptLayer() {
            guard claimsLayer, displayLayer.superlayer !== layer else { return }
            layer.addSublayer(displayLayer)
            displayLayer.frame = bounds
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { adoptLayer() }
        }
        #if os(tvOS)
        /// UIWindow.avDisplayManager is an AVKit category: the app links AVKit
        /// explicitly (ld drops autolinked frameworks it sees no symbol from).
        static let displayManagerSelector = NSSelectorFromString("avDisplayManager")

        /// Asks for this video's mode (refresh rate and dynamic range). The
        /// choice is kept when the player goes away: resetting it would switch
        /// the TV back to the menu's default mode and again on the next
        /// channel. It only changes when another video asks for something else.
        func requestDisplayMode(frameRate: Double?, format: CMVideoFormatDescription?) {
            guard let window, let frameRate, let format,
                  window.responds(to: Self.displayManagerSelector) else { return }   // AVKit not loaded: no mode switch, never a crash
            let criteria = AVDisplayCriteria(refreshRate: Float(frameRate), formatDescription: format)
            if window.avDisplayManager.preferredDisplayCriteria != criteria {
                window.avDisplayManager.preferredDisplayCriteria = criteria
            }
        }
        #endif
    }

    func makeUIView(context: Context) -> LayerHost { LayerHost(displayLayer: renderer.displayLayer) }
    func updateUIView(_ uiView: LayerHost, context: Context) {
        uiView.claimsLayer = claimsLayer
        uiView.adoptLayer()
        #if os(tvOS)
        if matchesDisplayMode {
            uiView.requestDisplayMode(frameRate: frameRate, format: renderer.displayedFormat)
        }
        #endif
    }
}
#endif
