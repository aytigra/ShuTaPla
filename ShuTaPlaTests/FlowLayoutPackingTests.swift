//
//  FlowLayoutPackingTests.swift
//  ShuTaPlaTests
//
//  The line breaking behind `FlowLayout`, exercised without a live layout: where each box lands and
//  how big the run comes out. `FlowLayout` measures and places through this one function, so these
//  cover both — the failure it rules out is a chip placed outside the box the measurement reserved.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite("FlowLayout packing")
struct FlowLayoutPackingTests {
    private func pack(_ sizes: [CGSize], maxWidth: CGFloat) -> FlowLayoutPacking.Result {
        FlowLayoutPacking.pack(sizes: sizes, maxWidth: maxWidth, spacing: 6, lineSpacing: 6)
    }

    @Test func aRunThatFitsStaysOnOneLine() {
        let packed = pack([CGSize(width: 40, height: 20), CGSize(width: 30, height: 24)], maxWidth: 200)
        #expect(packed.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 46, y: 0)])
        // As wide as the line it filled, not as wide as it was allowed to be; as tall as the tallest.
        #expect(packed.size == CGSize(width: 76, height: 24))
    }

    @Test func aBoxThatWouldOverflowStartsTheNextLine() {
        let packed = pack(
            [CGSize(width: 40, height: 20), CGSize(width: 30, height: 20), CGSize(width: 50, height: 20)],
            maxWidth: 80
        )
        #expect(packed.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 46, y: 0), CGPoint(x: 0, y: 26)])
        // The widest line is the first (40 + 6 + 30), and the height carries the line spacing.
        #expect(packed.size == CGSize(width: 76, height: 46))
    }

    /// What a squeezed block relies on: `FlowLayout` re-measures an oversized subview against the
    /// line and hands the wrapped size back here, which must then be placed rather than re-broken.
    @Test func aBoxWiderThanTheLineIsPlacedRatherThanDropped() {
        let packed = pack([CGSize(width: 500, height: 40)], maxWidth: 80)
        #expect(packed.origins == [CGPoint(x: 0, y: 0)])
        #expect(packed.size == CGSize(width: 500, height: 40))
    }

    @Test func nothingToPackOccupiesNothing() {
        let packed = pack([], maxWidth: 200)
        #expect(packed.origins.isEmpty)
        #expect(packed.size == .zero)
    }
}
