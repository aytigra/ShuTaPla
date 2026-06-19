//
//  FileCollectionLayoutTests.swift
//  ShuTaPlaTests
//
//  The gallery's column count drives 2D keyboard navigation, so it must match the
//  columns `LazyVGrid` actually laid out. It is measured from the laid-out cells'
//  leading edges: cells in one column share an edge, so the count of distinct edges
//  (to the nearest point) is the column count. No cells floors at one column.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct FileCollectionLayoutTests {

    @Test func distinctEdgesCountAsColumns() {
        // Three columns over two rows: six cells, three distinct leading edges.
        let minXs: [CGFloat] = [12, 174, 336, 12, 174, 336]
        #expect(FileCollectionLayout.columnCount(fromCellMinXs: minXs) == 3)
    }

    @Test func subPixelDriftCollapsesToOneEdge() {
        // The same column measured across rows can drift by a fraction of a point;
        // rounding keeps it one column rather than inflating the count.
        let minXs: [CGFloat] = [12.0, 12.4, 11.6, 12.49]
        #expect(FileCollectionLayout.columnCount(fromCellMinXs: minXs) == 1)
    }

    @Test func noCellsFloorsAtOneColumn() {
        #expect(FileCollectionLayout.columnCount(fromCellMinXs: []) == 1)
    }

    @Test func oneCellIsOneColumn() {
        #expect(FileCollectionLayout.columnCount(fromCellMinXs: [12]) == 1)
    }
}
