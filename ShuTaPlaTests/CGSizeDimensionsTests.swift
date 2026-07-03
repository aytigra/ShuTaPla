//
//  CGSizeDimensionsTests.swift
//  ShuTaPlaTests
//
//  `CGSize.dimensionsText`: the `"W×H"` pixel-dimensions string shown in the Manager's
//  file list and gallery.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct CGSizeDimensionsTests {

    @Test(arguments: [
        (CGSize(width: 1920, height: 1080), "1920×1080"),
        (CGSize(width: 1280, height: 720), "1280×720"),
        (CGSize(width: 1, height: 1), "1×1"),
    ])
    func formats(_ size: CGSize, _ expected: String) {
        #expect(size.dimensionsText == expected)
    }

    @Test func usesMultiplicationSignNotLetterX() {
        let text = CGSize(width: 800, height: 600).dimensionsText
        #expect(text.contains("×"))
        #expect(!text.contains("x"))
    }

    @Test func truncatesFractionalPixels() {
        #expect(CGSize(width: 100.9, height: 50.4).dimensionsText == "100×50")
    }
}
