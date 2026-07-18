//
//  VirtualWindowTests.swift
//  ShuTaPlaTests
//
//  The pure windowing math behind `VirtualList`: content size from the count alone, the
//  padded/clamped visible band, the first-row boundary signal, and the clamped jump offset.
//  Fixed row height 20, overscan 2 unless a case says otherwise.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct VirtualWindowTests {

    private let window = VirtualWindow(rowHeight: 20, overscan: 2)

    // MARK: - Content height

    @Test func contentHeightIsCountTimesRowHeight() {
        #expect(window.contentHeight(count: 100) == 2000)
    }

    @Test func emptyContentIsZeroHeight() {
        #expect(window.contentHeight(count: 0) == 0)
    }

    // MARK: - Visible range

    @Test func bandAtTopStartsAtZeroAndPadsBelow() {
        // Viewport 200 tall at offset 0 covers rows 0..<10; +2 overscan below, none above.
        #expect(window.visibleRange(offset: 0, height: 200, count: 100) == 0..<12)
    }

    @Test func bandInMiddlePadsBothSides() {
        // Offset 400 → first visible row 20; viewport 200 → last visible 30; ±2 overscan.
        #expect(window.visibleRange(offset: 400, height: 200, count: 100) == 18..<32)
    }

    @Test func bandClampsToCountAtBottom() {
        // Scrolled to the end: upper edge never exceeds count.
        #expect(window.visibleRange(offset: 1800, height: 200, count: 100) == 88..<100)
    }

    @Test func partialRowOffsetRoundsToCoverBoth() {
        // Offset 410 shows the tail of row 20 and head of row 30; rounding keeps both, then overscan.
        #expect(window.visibleRange(offset: 410, height: 200, count: 100) == 18..<33)
    }

    @Test func negativeOffsetClampsLowerToZero() {
        // Rubber-band overscroll above the top must not produce negative indices. The viewport's
        // bottom edge (150) still lands in row 7, so the band is rows 0..<8 plus overscan below.
        #expect(window.visibleRange(offset: -50, height: 200, count: 100) == 0..<10)
    }

    @Test func emptyWhenNoRows() {
        #expect(window.visibleRange(offset: 0, height: 200, count: 0).isEmpty)
    }

    @Test func emptyWhenViewportDegenerate() {
        #expect(window.visibleRange(offset: 0, height: 0, count: 100).isEmpty)
    }

    @Test func bandNeverExceedsCountWhenShorterThanViewport() {
        // Only 3 rows but a tall viewport: band is exactly the 3 rows, no overrun.
        #expect(window.visibleRange(offset: 0, height: 500, count: 3) == 0..<3)
    }

    // MARK: - First-row boundary signal

    @Test func firstRowIsFlooredIndex() {
        #expect(window.firstRow(offset: 0, count: 100) == 0)
        #expect(window.firstRow(offset: 19, count: 100) == 0)
        #expect(window.firstRow(offset: 20, count: 100) == 1)
        #expect(window.firstRow(offset: 405, count: 100) == 20)
    }

    @Test func firstRowClampsToLastIndexAtBottom() {
        // A far-past-end offset (rubber band at bottom) clamps to the last valid index.
        #expect(window.firstRow(offset: 5000, count: 100) == 99)
    }

    @Test func firstRowIsZeroWhenEmpty() {
        #expect(window.firstRow(offset: 0, count: 0) == 0)
    }

    // MARK: - Row y

    @Test func rowYIsIndexTimesHeight() {
        #expect(window.offsetY(of: 0) == 0)
        #expect(window.offsetY(of: 7) == 140)
    }

    // MARK: - Jump offset

    @Test func targetOffsetPlacesRowAtTop() {
        // Row 20 sits at y=400 with room below, so it lands at the top of the viewport.
        #expect(window.targetOffset(index: 20, count: 100, height: 200) == 400)
    }

    @Test func targetOffsetClampsAtBottomEdge() {
        // The last row can't scroll to the top — clamp to content height minus viewport.
        // 100*20 - 200 = 1800.
        #expect(window.targetOffset(index: 99, count: 100, height: 200) == 1800)
    }

    @Test func targetOffsetIsZeroWhenContentFitsViewport() {
        // Content shorter than the viewport never scrolls.
        #expect(window.targetOffset(index: 2, count: 3, height: 500) == 0)
    }

    @Test func targetOffsetForFirstRowIsZero() {
        #expect(window.targetOffset(index: 0, count: 100, height: 200) == 0)
    }

    // MARK: - Reveal offset (minimal scroll-into-view)

    @Test func revealKeepsOffsetWhenRowFullyVisible() {
        // Viewport 200 at offset 0 shows rows 0..<10; row 5 (y 100..<120) is fully inside, no scroll.
        #expect(window.revealOffset(index: 5, currentOffset: 0, height: 200, count: 100) == 0)
    }

    @Test func revealKeepsOffsetForLastVisibleRowAtBottomEdge() {
        // Row 9 (y 180..<200) exactly fills the bottom edge — still fully visible, no scroll.
        #expect(window.revealOffset(index: 9, currentOffset: 0, height: 200, count: 100) == 0)
    }

    @Test func revealScrollsRowBelowToBottomEdge() {
        // Row 10 (y 200..<220) sits just past the bottom: scroll one row so its bottom aligns.
        #expect(window.revealOffset(index: 10, currentOffset: 0, height: 200, count: 100) == 20)
    }

    @Test func revealScrollsRowAboveToTopEdge() {
        // At offset 400 rows 20..<30 show; row 15 (y 300) is above — align its top to the viewport top.
        #expect(window.revealOffset(index: 15, currentOffset: 400, height: 200, count: 100) == 300)
    }

    @Test func revealKeepsOffsetMidContentWhenVisible() {
        // At offset 400, row 25 (y 500..<520) is inside the viewport (400..<600) — no scroll.
        #expect(window.revealOffset(index: 25, currentOffset: 400, height: 200, count: 100) == 400)
    }

    @Test func revealClampsAtBottomForLastRow() {
        // The last row can never leave a gap below content: clamp to content minus viewport.
        #expect(window.revealOffset(index: 99, currentOffset: 0, height: 200, count: 100) == 1800)
    }
}
