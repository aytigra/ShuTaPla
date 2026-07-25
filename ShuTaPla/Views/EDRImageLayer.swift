//
//  EDRImageLayer.swift
//  ShuTaPla
//
//  Hosts a decoded `CGImage` in a raw `CALayer` so HDR content reaches the OS tone-mapper. The
//  `CGImage` (set as the layer's `contents`) carries its own HDR colour space; the layer opts into
//  extended dynamic range when the image is HDR and the hosting screen supports it
//  (`HDRImageConfig`), and `contentsGravity` scales it per the fit mode. A raw layer — not
//  `NSImageView` — because only `contentsGravity` can express aspect-fill. Shared by the player and
//  the peek.
//

import SwiftUI
import AppKit

struct EDRImageLayer: NSViewRepresentable {
    let image: CGImage
    let fitMode: ImageFitMode

    func makeNSView(context: Context) -> BackingLayerView {
        let view = BackingLayerView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: BackingLayerView, context: Context) {
        view.image = image
        view.fitMode = fitMode
        view.refreshLayerConfig()
    }

    /// The image is the view's backing layer's `contents`; a custom backing layer keeps AppKit from
    /// clobbering it on redraw and resizes it with the view for free. The layer configuration lives
    /// here so `viewDidChangeBackingProperties` can re-apply it: `updateNSView` runs only on a
    /// SwiftUI state change, but the backing scale and screen EDR headroom change when the window
    /// moves between displays, and both must follow the new screen.
    final class BackingLayerView: NSView {
        var image: CGImage?
        var fitMode: ImageFitMode = .fit

        override func makeBackingLayer() -> CALayer { CALayer() }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            refreshLayerConfig()
        }

        /// Recompute scale + EDR from the hosting screen/window and push them to the layer.
        func refreshLayerConfig() {
            let screen = window?.screen ?? NSScreen.main
            let supportsEDR = screen?.supportsEDR ?? false
            let scale = window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 2
            applyLayerConfig(backingScale: scale, displaySupportsEDR: supportsEDR)
        }

        /// Push the decided configuration onto the layer from explicit display inputs — the seam
        /// both `refreshLayerConfig` and the tests drive.
        func applyLayerConfig(backingScale: CGFloat, displaySupportsEDR: Bool) {
            guard let layer, let image else { return }
            let config = HDRImageConfig.decide(fitMode: fitMode, imageIsHDR: image.isHDR, displaySupportsEDR: displaySupportsEDR)
            layer.contentsScale = backingScale
            layer.contents = image   // the CGImage carries its own (HDR) colour space
            layer.preferredDynamicRange = config.preferredDynamicRange
            layer.contentsGravity = config.contentsGravity
        }
    }
}
