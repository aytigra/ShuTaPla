//
//  GalleryGridTests.swift
//  ShuTaPlaTests
//
//  The gallery packs its columns from the available width — the column count (which drives 2D
//  keyboard navigation) and the tile width — replicating `LazyVGrid`'s `.adaptive` packing, and
//  derives a fixed row height from that tile width for the windowed list.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct GalleryGridTests {

    // MARK: - Adaptive grid metrics

    @Test func nilMinFallsBackToDefault() {
        let metrics = GalleryGrid.gridMetrics(min: nil)
        #expect(metrics.min == GalleryGrid.galleryMinItemWidth)
        #expect(metrics.max == GalleryGrid.galleryMinItemWidth * GalleryGrid.galleryMaxRatio)
    }

    @Test(arguments: [100.0, 200.0, 360.0, 600.0])
    func maxIsRatioTimesChosenMin(_ chosen: Double) {
        let metrics = GalleryGrid.gridMetrics(min: chosen)
        #expect(metrics.min == CGFloat(chosen))
        #expect(metrics.max == CGFloat(chosen) * GalleryGrid.galleryMaxRatio)
    }

    // MARK: - Adaptive packing (column count + tile width from width)

    @Test func packsAsManyMinWidthColumnsAsFit() {
        // 800 wide, 200 min, 4 spacing: (800+4)/(200+4) = 3.94 → 3 columns, each sharing the
        // width evenly: (800 - 2·4)/3 = 264.
        let layout = GalleryGrid.gridLayout(width: 800, min: 200, max: 360, spacing: 4)
        #expect(layout.columns == 3)
        #expect(layout.tileWidth == 264)
    }

    @Test func floorsAtOneColumnWhenNarrowerThanMin() {
        // Narrower than a single minimum tile still yields one column filling the width.
        let layout = GalleryGrid.gridLayout(width: 150, min: 200, max: 360, spacing: 4)
        #expect(layout.columns == 1)
        #expect(layout.tileWidth == 150)
    }

    @Test func addsAColumnAsWidthGrows() {
        // 1000 wide, 200 min, 4 spacing: (1004)/(204) = 4.9 → 4 columns, (1000 - 3·4)/4 = 247.
        let layout = GalleryGrid.gridLayout(width: 1000, min: 200, max: 360, spacing: 4)
        #expect(layout.columns == 4)
        #expect(layout.tileWidth == 247)
    }

    @Test func tileWidthClampsAtMax() {
        // Two columns whose even share (260) exceeds the max (250) clamp to the max, leaving the
        // row unfilled rather than over-wide.
        let layout = GalleryGrid.gridLayout(width: 520, min: 200, max: 250, spacing: 0)
        #expect(layout.columns == 2)
        #expect(layout.tileWidth == 250)
    }

    @Test func degenerateWidthIsOneColumn() {
        let layout = GalleryGrid.gridLayout(width: 0, min: 200, max: 360, spacing: 4)
        #expect(layout.columns == 1)
    }

    // MARK: - Row height from tile width

    @Test func rowHeightIsThumbnailPlusChrome() {
        // Tile 206 wide: thumbnail (206 - 2·3)·3/4 = 150, plus the 42-point caption chrome = 192.
        #expect(GalleryGrid.rowHeight(tileWidth: 206) == 192)
    }

    @Test func rowHeightGrowsWithTileWidth() {
        #expect(GalleryGrid.rowHeight(tileWidth: 400) > GalleryGrid.rowHeight(tileWidth: 200))
    }
}
