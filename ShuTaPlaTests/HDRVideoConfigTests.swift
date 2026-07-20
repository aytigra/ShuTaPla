//
//  HDRVideoConfigTests.swift
//  ShuTaPlaTests
//
//  Task 19 step 1 — the pure EDR decision: `(gamma, primaries, displaySupportsEDR)` maps to an
//  EDR config for HDR content on a capable display, and to SDR passthrough for everything else.
//  No GL/layer wiring is exercised; the enum colour space keeps the decision testable without a
//  surface.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct HDRVideoConfigTests {

    /// The EDR configuration for the two wide-gamut PQ/HLG combinations, on a capable display.
    @Test(arguments: [
        // Both HDR transfer functions pair with either wide gamut → EDR in that gamut's PQ space.
        ("pq", "bt.2020", HDRVideoConfig(extendedDynamicRange: true, colorSpace: .itur_2100_PQ,
                                         targetPrimaries: "bt.2020", targetTransfer: "pq", targetPeak: "auto")),
        ("hlg", "bt.2020", HDRVideoConfig(extendedDynamicRange: true, colorSpace: .itur_2100_PQ,
                                          targetPrimaries: "bt.2020", targetTransfer: "pq", targetPeak: "auto")),
        ("pq", "display-p3", HDRVideoConfig(extendedDynamicRange: true, colorSpace: .displayP3_PQ,
                                            targetPrimaries: "display-p3", targetTransfer: "pq", targetPeak: "auto")),
        ("hlg", "display-p3", HDRVideoConfig(extendedDynamicRange: true, colorSpace: .displayP3_PQ,
                                             targetPrimaries: "display-p3", targetTransfer: "pq", targetPeak: "auto")),
    ] as [(String, String, HDRVideoConfig)])
    func hdrContentOnCapableDisplay(gamma: String, primaries: String, expected: HDRVideoConfig) {
        #expect(HDRVideoConfig.decide(gamma: gamma, primaries: primaries, displaySupportsEDR: true) == expected)
    }

    /// SDR content, non-HDR/unknown primaries — all fall back to SDR even on a capable display.
    @Test(arguments: [
        ("bt.1886", "bt.709"),   // ordinary SDR
        ("pq", "bt.709"),        // HDR transfer but narrow gamut → not eligible
        ("hlg", "bt.601-625"),   // HDR transfer but narrow gamut → not eligible
        ("pq", "prophoto"),      // unknown/unsupported primaries
        ("srgb", "display-p3"),  // wide gamut but SDR transfer
    ] as [(String, String)])
    func nonHDRContentIsSDR(gamma: String, primaries: String) {
        #expect(HDRVideoConfig.decide(gamma: gamma, primaries: primaries, displaySupportsEDR: true) == .sdr)
    }

    /// A display without EDR headroom never engages EDR, even for eligible HDR content.
    @Test(arguments: [
        ("pq", "bt.2020"),
        ("hlg", "display-p3"),
    ] as [(String, String)])
    func sdrDisplayNeverEngagesEDR(gamma: String, primaries: String) {
        #expect(HDRVideoConfig.decide(gamma: gamma, primaries: primaries, displaySupportsEDR: false) == .sdr)
    }

    /// Each colour-space case resolves to the matching concrete `CGColorSpace` the layer tags its
    /// framebuffer with — the one bit of step-3 wiring provable without a GL surface. Compared by
    /// bridged name to sidestep `CFString`/`CGColorSpace` equality.
    @Test(arguments: [
        (HDRVideoConfig.ColorSpace.sRGB, CGColorSpace.sRGB as String),
        (.displayP3_PQ, CGColorSpace.displayP3_PQ as String),
        (.itur_2100_PQ, CGColorSpace.itur_2100_PQ as String),
    ] as [(HDRVideoConfig.ColorSpace, String)])
    func colorSpaceResolvesToCGColorSpace(space: HDRVideoConfig.ColorSpace, expectedName: String) {
        #expect(space.cgColorSpace?.name as String? == expectedName)
    }
}
