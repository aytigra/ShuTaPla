//
//  FixedChunksTests.swift
//  ShuTaPlaTests
//
//  The pure index chunking shared by `PagedList` (rows into pages) and `GalleryPaging` (items into
//  grid rows): the chunk count for a total, the index range within a chunk, and the chunk holding an
//  index. The size-10 cases mirror `PagedList`'s page granularity; size-4 the gallery's columns.
//

import Testing
@testable import ShuTaPla

@Suite struct FixedChunksTests {

    private let pages = FixedChunks(size: 10)

    // MARK: - Count

    @Test func countRoundsUpAPartialFinalChunk() {
        #expect(pages.count(40) == 4)   // exactly divides
        #expect(pages.count(41) == 5)   // one extra element needs another chunk
        #expect(pages.count(1) == 1)
    }

    @Test func emptyHasNoChunks() {
        #expect(pages.count(0) == 0)
    }

    @Test func degenerateSizeHasNoChunks() {
        #expect(FixedChunks(size: 0).count(40) == 0)
    }

    // MARK: - Range

    @Test func fullChunkSpansItsSize() {
        // 12 elements at size 10: chunk 0 is 0..<10, chunk 1 the remaining 10..<12.
        #expect(pages.range(0, of: 12) == 0..<10)
        #expect(pages.range(1, of: 12) == 10..<12)
    }

    @Test func shortFinalChunkClampsToTotal() {
        #expect(FixedChunks(size: 4).range(10, of: 41) == 40..<41)
    }

    @Test func chunkPastTheEndIsEmpty() {
        // A chunk index beyond the content (a stale window as the sequence shrinks) yields nothing.
        #expect(pages.range(5, of: 12).isEmpty)
    }

    // MARK: - Chunk of an index

    @Test func indexMapsToItsChunk() {
        #expect(FixedChunks(size: 4).chunk(of: 0) == 0)
        #expect(FixedChunks(size: 4).chunk(of: 3) == 0)
        #expect(FixedChunks(size: 4).chunk(of: 4) == 1)
        #expect(FixedChunks(size: 4).chunk(of: 40) == 10)
    }

    @Test func degenerateSizeMapsToChunkZero() {
        #expect(FixedChunks(size: 0).chunk(of: 12) == 0)
    }

    // MARK: - Paging (rows per page from a target item span)

    @Test func pagingHoldsAboutTargetItemsRegardlessOfColumns() {
        // Target 100 items: the row span is 100/columns rounded to nearest, so the item span per page
        // stays near 100 however wide the rows are.
        #expect(FixedChunks.paging(targetItems: 100, itemsPerRow: 1).size == 100)   // list: one item/row
        #expect(FixedChunks.paging(targetItems: 100, itemsPerRow: 3).size == 33)    // 99 items
        #expect(FixedChunks.paging(targetItems: 100, itemsPerRow: 7).size == 14)    // 98 items
        #expect(FixedChunks.paging(targetItems: 100, itemsPerRow: 10).size == 10)   // 100 items
    }

    @Test func pagingFloorsToOneRow() {
        // A row far wider than the target still spans at least one row (round would land on 0).
        #expect(FixedChunks.paging(targetItems: 100, itemsPerRow: 300).size == 1)
    }

    @Test func pagingGuardsZeroItemsPerRow() {
        // A zero row width can't divide; the guard keeps it off the target rather than trapping.
        #expect(FixedChunks.paging(targetItems: 100, itemsPerRow: 0).size == 100)
    }
}
