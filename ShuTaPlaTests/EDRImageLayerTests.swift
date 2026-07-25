//
//  EDRImageLayerTests.swift
//  ShuTaPlaTests
//
//  The layer-config seam of `EDRImageLayer.BackingLayerView` (F9): `applyLayerConfig` pushes the
//  backing scale and the EDR opt-in from its explicit display inputs, so re-running it after a
//  display move re-scales and re-gates the layer. `updateNSView` alone runs only on a SwiftUI
//  state change; the on-move refresh (`viewDidChangeBackingProperties` → `refreshLayerConfig`)
//  reads the live screen/window and is verified in-app — the screen/window seam has no analogue
//  in the test host. Only the pure-input apply is exercised here.
//

import Testing
import AppKit
import QuartzCore
@testable import ShuTaPla

@Suite @MainActor struct EDRImageLayerTests {

    /// A tiny decoded image, HDR (PQ colour space) or SDR (device RGB) — the only bit
    /// `applyLayerConfig` reads off the image is `isHDR`.
    private func makeCGImage(hdr: Bool) throws -> CGImage {
        let space = hdr
            ? try #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
            : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = hdr
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: hdr ? 16 : 8,
            bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo))
        return try #require(context.makeImage())
    }

    /// Re-applying the seam with new display inputs re-scales and re-gates the layer — the refresh
    /// a display move needs and a one-shot `updateNSView` can't give. An HDR image at `.cover` on a
    /// 1× EDR display opts into `.high`; the same view moved to a 2× SDR display drops to
    /// `.standard`, while the gravity (fit mode) stays put.
    @Test func applyLayerConfigFollowsDisplayInputs() throws {
        let view = EDRImageLayer.BackingLayerView()
        view.wantsLayer = true
        let image = try makeCGImage(hdr: true)
        #expect(image.isHDR)
        view.image = image
        view.fitMode = .cover
        let layer = try #require(view.layer)

        view.applyLayerConfig(backingScale: 1, displaySupportsEDR: true)
        #expect(layer.contentsScale == 1)
        #expect(layer.preferredDynamicRange == .high)
        #expect(layer.contentsGravity == .resizeAspectFill)

        view.applyLayerConfig(backingScale: 2, displaySupportsEDR: false)
        #expect(layer.contentsScale == 2)
        #expect(layer.preferredDynamicRange == .standard)
        #expect(layer.contentsGravity == .resizeAspectFill)
    }
}
