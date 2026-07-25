//
//  NSScreenEDRTests.swift
//  ShuTaPlaTests
//
//  The shared `NSScreen.supportsEDR` predicate that both HDR output paths gate on (the image
//  layer's EDR opt-in and the video engine's mpv EDR hint). The live screen headroom is whatever
//  the test host's display reports, so the test pins the extraction to the raw comparison it
//  replaced rather than a fixed truth value — proving `supportsEDR` is exactly that predicate.
//

import Testing
import AppKit
@testable import ShuTaPla

@Suite @MainActor struct NSScreenEDRTests {

    /// `supportsEDR` is precisely `maximumPotentialExtendedDynamicRangeColorComponentValue > 1`,
    /// the expression the two call sites inlined before the fold — same result on any display.
    @Test func supportsEDRMatchesRawHeadroomComparison() throws {
        let screen = try #require(NSScreen.main)
        #expect(screen.supportsEDR == (screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1))
    }
}
