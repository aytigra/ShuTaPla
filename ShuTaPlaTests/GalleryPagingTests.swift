//
//  GalleryPagingTests.swift
//  ShuTaPlaTests
//
//  The item↔row mapping behind `GalleryPagedList`: total grid rows from the item count, the item
//  indices in a row, and the row holding an item. Four columns unless a case says otherwise.
//

import Testing
@testable import ShuTaPla

@Suite struct GalleryPagingTests {

    private let paging = GalleryPaging(columns: 4)

    // MARK: - Total rows

    @Test func rowsRoundUpAPartialFinalRow() {
        #expect(paging.totalRows(itemCount: 40) == 10)   // exactly divides
        #expect(paging.totalRows(itemCount: 41) == 11)   // one extra item spills to a new row
        #expect(paging.totalRows(itemCount: 1) == 1)
    }

    @Test func emptyHasNoRows() {
        #expect(paging.totalRows(itemCount: 0) == 0)
    }

    @Test func degenerateColumnsHasNoRows() {
        #expect(GalleryPaging(columns: 0).totalRows(itemCount: 40) == 0)
    }

    // MARK: - Items in a row

    @Test func fullRowSpansItsColumns() {
        #expect(paging.items(inRow: 2, itemCount: 41) == 8..<12)
    }

    @Test func shortFinalRowPacksOnlyRealCells() {
        // 41 items, 4 columns: row 10 holds just the single trailing item.
        #expect(paging.items(inRow: 10, itemCount: 41) == 40..<41)
    }

    @Test func rowPastTheEndIsEmpty() {
        #expect(paging.items(inRow: 20, itemCount: 41).isEmpty)
    }

    // MARK: - Row of an item

    @Test func itemMapsToItsRow() {
        #expect(paging.row(ofItem: 0) == 0)
        #expect(paging.row(ofItem: 3) == 0)
        #expect(paging.row(ofItem: 4) == 1)
        #expect(paging.row(ofItem: 40) == 10)
    }

    @Test func degenerateColumnsMapToRowZero() {
        #expect(GalleryPaging(columns: 0).row(ofItem: 12) == 0)
    }
}
