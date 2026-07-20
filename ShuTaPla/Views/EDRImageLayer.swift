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

    func makeNSView(context: Context) -> NSView {
        let view = BackingLayerView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        let screen = view.window?.screen ?? NSScreen.main
        let supportsEDR = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let config = HDRImageConfig.decide(fitMode: fitMode, imageIsHDR: image.isHDR, displaySupportsEDR: supportsEDR)
        layer.contentsScale = view.window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 2
        layer.contents = image   // the CGImage carries its own (HDR) colour space
        layer.preferredDynamicRange = config.preferredDynamicRange
        layer.contentsGravity = config.contentsGravity
    }

    /// The image is the view's backing layer's `contents`; a custom backing layer keeps AppKit from
    /// clobbering it on redraw and resizes it with the view for free.
    private final class BackingLayerView: NSView {
        override func makeBackingLayer() -> CALayer { CALayer() }
    }
}
