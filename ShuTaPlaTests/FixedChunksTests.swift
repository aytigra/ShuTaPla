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
}
