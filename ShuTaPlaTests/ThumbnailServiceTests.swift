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
import ImageIO
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

/// Writes a PNG whose every pixel has alpha 1.0 (`opaque`) or a uniform partial
/// alpha (`!opaque`). `.copy` compositing replaces the freshly allocated bitmap's
/// undefined contents outright, so the alpha is exactly what's filled.
private func writeFilledPNG(width: Int, height: Int, opaque: Bool, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.compositingOperation = .copy
    NSColor(red: 0.8, green: 0.3, blue: 0.2, alpha: opaque ? 1.0 : 0.4).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

/// Whether the encoded image carries an alpha channel, decoded straight from the
/// thumbnail bytes. `nil` when the data can't be read as an image.
private func hasAlphaChannel(_ data: Data) -> Bool? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    switch cg.alphaInfo {
    case .none, .noneSkipLast, .noneSkipFirst: return false
    default: return true
    }
}

/// Whether `data` is an ISO base-media container (HEIC), identified by the `ftyp`
/// box at offset 4 — distinguishing it from the PNG the source images are.
private func isISOMediaContainer(_ data: Data) -> Bool {
    guard data.count >= 8 else { return false }
    return data.subdata(in: 4..<8) == Data("ftyp".utf8)
}

// MARK: - Tests

struct ThumbnailServiceTests {

    @Test
    func imageThumbnailGeneratedAtCorrectSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "wide.png")
        try writePNG(width: 200, height: 100, to: fileURL)

        let data = try #require(await ThumbnailService.renderThumbnail(at: fileURL, isVideo: false, maxPixelSize: 64).data)
        let size = try #require(pixelSize(of: data))

        // The longest edge is scaled to maxPixelSize; the aspect ratio is kept.
        #expect(max(size.width, size.height) == 64)
        #expect(size.width == 64 && size.height == 32)
    }

    @Test
    func imageRenderReportsSourcePixelDimensions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "wide.png")
        try writePNG(width: 200, height: 100, to: fileURL)

        // The thumbnail is downscaled, but the reported dimensions are the source's true
        // pixel size (read from its header) — the gallery byproduct the sink caches.
        let rendered = await ThumbnailService.renderThumbnail(at: fileURL, isVideo: false, maxPixelSize: 64)
        #expect(rendered.data != nil)
        #expect(rendered.metadata.width == 200)
        #expect(rendered.metadata.height == 100)
        #expect(rendered.metadata.duration == nil)   // stills have no timeline
    }

    @Test
    func renderedThumbnailIsHeic() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "img.png")
        try writeFilledPNG(width: 64, height: 64, opaque: true, to: fileURL)

        let data = try #require(await ThumbnailService.renderThumbnail(at: fileURL, isVideo: false, maxPixelSize: 64).data)
        #expect(isISOMediaContainer(data), "thumbnail should be encoded as HEIC, not PNG")
    }

    @Test
    func opaqueThumbnailDropsAlphaChannel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "opaque.png")
        try writeFilledPNG(width: 64, height: 64, opaque: true, to: fileURL)

        let data = try #require(await ThumbnailService.renderThumbnail(at: fileURL, isVideo: false, maxPixelSize: 64).data)
        // A fully opaque source has its redundant alpha channel flattened away.
        #expect(hasAlphaChannel(data) == false)
    }

    @Test
    func transparentThumbnailKeepsAlphaChannel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "transparent.png")
        try writeFilledPNG(width: 64, height: 64, opaque: false, to: fileURL)

        let data = try #require(await ThumbnailService.renderThumbnail(at: fileURL, isVideo: false, maxPixelSize: 64).data)
        // Genuine transparency is preserved rather than flattened.
        #expect(hasAlphaChannel(data) == true)
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

        // Replace the cached bytes with a different but still-decodable image: a true
        // cache hit returns these verbatim instead of regenerating from the source.
        let key = try #require(await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 64))
        let cacheFile = cacheDir.appending(path: "\(key).heic")
        let sentinelURL = dir.appending(path: "sentinel.png")
        try writePNG(width: 16, height: 16, to: sentinelURL)
        let sentinel = try Data(contentsOf: sentinelURL)
        try sentinel.write(to: cacheFile)

        let second = await service.thumbnailData(bookmark: bookmark, relativePath: "img.png", isVideo: false, maxPixelSize: 64)
        #expect(second == sentinel)
    }

    @Test
    func corruptDiskCacheIsRegeneratedNotServed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let fileURL = dir.appending(path: "img.png")
        try writePNG(width: 80, height: 80, to: fileURL)
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let service = await ThumbnailService(cacheDirectory: cacheDir)
        let key = try #require(await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png", maxPixelSize: 64))
        let cacheFile = cacheDir.appending(path: "\(key).heic")

        // A 0-byte cache file (an interrupted prior write) reads successfully but can't
        // be decoded, so it must not be treated as a hit.
        try Data().write(to: cacheFile)

        let data = try #require(
            await service.thumbnailData(bookmark: bookmark, relativePath: "img.png", isVideo: false, maxPixelSize: 64)
        )
        // The bad file is discarded and a real thumbnail regenerated from the source.
        #expect(!data.isEmpty)
        #expect(isISOMediaContainer(data))
    }
}
