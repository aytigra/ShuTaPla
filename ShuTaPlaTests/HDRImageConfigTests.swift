//
//  HDRImageConfigTests.swift
//  ShuTaPlaTests
//
//  Task 19 step 4 — the pure image-layer decision: the fit mode maps to a `contentsGravity`, and
//  EDR engages only when the image is HDR and the display can show it. No layer/screen wiring is
//  exercised; the on-screen EDR result is a by-hand check on a capable display.
//

import Testing
import QuartzCore
@testable import ShuTaPla

@Suite struct HDRImageConfigTests {

    /// Each fit mode maps to its layer gravity: fit letterboxes, cover fills-and-crops, original
    /// is a centred 1:1.
    @Test(arguments: [
        (ImageFitMode.fit, CALayerContentsGravity.resizeAspect),
        (.cover, .resizeAspectFill),
        (.original, .center),
    ] as [(ImageFitMode, CALayerContentsGravity)])
    func fitModeMapsToGravity(fitMode: ImageFitMode, expected: CALayerContentsGravity) {
        #expect(HDRImageConfig.gravity(for: fitMode) == expected)
        #expect(HDRImageConfig.decide(fitMode: fitMode, imageIsHDR: true, displaySupportsEDR: true).contentsGravity == expected)
    }

    /// The player's base frame per fit mode: `.fit`/`.cover` frame the surface (gravity does the
    /// scaling), `.original` frames the picture pixel-perfectly — pixels over the display scale,
    /// matching the 1:1 render of `.center` gravity with `contentsScale = displayScale` — so the
    /// frame hugs the picture and pan/zoom can't roam empty margins.
    @Test(arguments: [
        (ImageFitMode.original, 2.0, CGSize(width: 1000, height: 500)),
        (.original, 1.0, CGSize(width: 2000, height: 1000)),
        (.fit, 2.0, CGSize(width: 800, height: 600)),
        (.cover, 2.0, CGSize(width: 800, height: 600)),
    ] as [(ImageFitMode, CGFloat, CGSize)])
    func baseSizeFramesRenderedPicture(fitMode: ImageFitMode, displayScale: CGFloat, expected: CGSize) {
        let size = fitMode.baseSize(imagePixelSize: CGSize(width: 2000, height: 1000),
                                    surface: CGSize(width: 800, height: 600),
                                    displayScale: displayScale)
        #expect(size == expected)
    }

    /// EDR opts in (`.high`) only when the image is HDR and the display supports it; every other
    /// combination stays `.standard`. The gravity is unaffected by the EDR gate.
    @Test(arguments: [
        (true, true, CALayer.DynamicRange.high),
        (true, false, .standard),   // HDR image, SDR display
        (false, true, .standard),   // SDR image, capable display
        (false, false, .standard),
    ] as [(Bool, Bool, CALayer.DynamicRange)])
    func edrGatedOnImageAndDisplay(imageIsHDR: Bool, displaySupportsEDR: Bool, expected: CALayer.DynamicRange) {
        let config = HDRImageConfig.decide(fitMode: .fit, imageIsHDR: imageIsHDR, displaySupportsEDR: displaySupportsEDR)
        #expect(config.preferredDynamicRange == expected)
        #expect(config.contentsGravity == .resizeAspect)
    }
}
