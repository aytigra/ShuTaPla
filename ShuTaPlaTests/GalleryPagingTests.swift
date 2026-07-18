//
//  GalleryPagingTests.swift
//  ShuTaPlaTests
//
//  The pure page/row/item chunking behind `GalleryPagedList`: total rows and pages from the item
//  count, the grid rows in a page, the item indices in a row, and the row holding an item. Four
//  columns, ten rows per page unless a case says otherwise.
//

import Testing
@testable import ShuTaPla

@Suite struct GalleryPagingTests {

    private let paging = GalleryPaging(columns: 4, rowsPerPage: 10)

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
        #expect(GalleryPaging(columns: 0, rowsPerPage: 10).totalRows(itemCount: 40) == 0)
    }

    // MARK: - Total pages

    @Test func pagesRoundUpAPartialFinalPage() {
        // 40 rows / 10 per page = 4 pages exactly; one more row needs a fifth.
        #expect(paging.totalPages(itemCount: 160) == 4)
        #expect(paging.totalPages(itemCount: 161) == 5)
    }

    @Test func emptyHasNoPages() {
        #expect(paging.totalPages(itemCount: 0) == 0)
    }

    // MARK: - Rows in a page

    @Test func fullPageSpansItsRows() {
        // 45 items → 12 rows; page 0 is rows 0..<10, page 1 the remaining 10..<12.
        #expect(paging.rows(inPage: 0, itemCount: 45) == 0..<10)
        #expect(paging.rows(inPage: 1, itemCount: 45) == 10..<12)
    }

    @Test func pagePastTheEndIsEmpty() {
        // A page index beyond the content (stale window as the sequence shrinks) yields no rows.
        #expect(paging.rows(inPage: 5, itemCount: 45).isEmpty)
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
        #expect(GalleryPaging(columns: 0, rowsPerPage: 10).row(ofItem: 12) == 0)
    }
}
