//
//  ThumbnailServiceTests.swift
//  ShuTaPlaTests
//
//  Task 8 — thumbnail generation and caching. Real image files in a temp folder
//  back a plain (non-scoped) bookmark, so generation and the disk cache run
//  without SwiftData or a sandbox.
//

import Testing
import Foundation
import AppKit
@testable import ShuTaPla

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShuTaPlaThumbnailTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes an opaque PNG of the given pixel dimensions to `url`.
private func writePNG(width: Int, height: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

private func pixelSize(of pngData: Data) -> (width: Int, height: Int)? {
    guard let rep = NSBitmapImageRep(data: pngData) else { return nil }
    return (rep.pixelsWide, rep.pixelsHigh)
}

// MARK: - Tests

struct ThumbnailServiceTests {

    @Test
    func imageThumbnailGeneratedAtCorrectSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "wide.png")
        try writePNG(width: 200, height: 100, to: fileURL)

        let data = try #require(await ThumbnailService.renderThumbnail(at: fileURL, isVideo: false, maxPixelSize: 64))
        let size = try #require(pixelSize(of: data))

        // The longest edge is scaled to maxPixelSize; the aspect ratio is kept.
        #expect(max(size.width, size.height) == 64)
        #expect(size.width == 64 && size.height == 32)
    }

    @Test
    func cacheKeyIsStableForUnchangedFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "img.png")
        try writePNG(width: 32, height: 32, to: fileURL)
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let key1 = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 128)
        let key2 = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 128)

        #expect(key1 != nil)
        #expect(key1 == key2)
    }

    @Test
    func cacheKeyChangesWhenModificationDateChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "img.png")
        try writePNG(width: 32, height: 32, to: fileURL)
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let before = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 128)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 1_000)],
            ofItemAtPath: fileURL.path
        )
        let after = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 128)

        #expect(before != nil)
        #expect(after != nil)
        #expect(before != after)
    }

    @Test
    func diskCacheServesWithoutRegenerating() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let fileURL = dir.appending(path: "img.png")
        try writePNG(width: 80, height: 80, to: fileURL)
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let service = await ThumbnailService(cacheDirectory: cacheDir)
        let first = await service.thumbnailData(bookmark: bookmark, relativePath: "img.png", isVideo: false, maxPixelSize: 64)
        #expect(first != nil)

        // Replace the cached bytes with a sentinel: a true cache hit returns these
        // verbatim instead of regenerating from the source image.
        let key = try #require(await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 64))
        let cacheFile = cacheDir.appending(path: "\(key).heic")
        let sentinel = Data("SENTINEL".utf8)
        try sentinel.write(to: cacheFile)

        let second = await service.thumbnailData(bookmark: bookmark, relativePath: "img.png", isVideo: false, maxPixelSize: 64)
        #expect(second == sentinel)
    }
}
