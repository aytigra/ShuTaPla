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

        let key1 = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png")
        let key2 = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png")

        #expect(key1 != nil)
        #expect(key1 == key2)
    }

    /// The key is the content fingerprint, not a path/mtime hash: a modification-date bump with no
    /// byte change leaves it identical (the stamp is gone), so an untouched file keeps its thumbnail.
    @Test
    func cacheKeyUnchangedByModificationDateAlone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "img.png")
        try writePNG(width: 32, height: 32, to: fileURL)
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let before = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 1_000)],
            ofItemAtPath: fileURL.path
        )
        let after = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png")

        #expect(before != nil)
        #expect(before == after)
    }

    /// The same bytes at two different relative paths key to the same cache entry — the cross-folder
    /// sharing this whole feature targets. A second load hits the `.heic` the first wrote.
    @Test
    func sameBytesAtDifferentPathsShareCacheKey() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(width: 48, height: 24, to: dir.appending(path: "rooted.png"))
        // Byte-for-byte copy at a different relative path (as if nested under another playlist).
        try Data(contentsOf: dir.appending(path: "rooted.png"))
            .write(to: dir.appending(path: "nested.png"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let rooted = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "rooted.png")
        let nested = await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "nested.png")
        #expect(rooted != nil)
        #expect(rooted == nested)
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
        let key = try #require(await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png"))
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
        let key = try #require(await ThumbnailService.cacheKey(bookmark: bookmark, relativePath: "img.png"))
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

    /// A record that already carries the fingerprint supplies it, so the produce path forms the
    /// very filename the first (computing) display wrote — the existing `.heic` is a hit, and there
    /// is nothing new to report back for persistence (`metadata.fingerprint == nil`).
    @MainActor @Test
    func suppliedFingerprintReproducesTheComputedCacheEntry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let fileURL = dir.appending(path: "img.png")
        try writePNG(width: 80, height: 80, to: fileURL)
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let service = ThumbnailService(cacheDirectory: cacheDir)
        // First display with no persisted fingerprint: computes it and writes the entry named by it.
        #expect(await service.thumbnailData(bookmark: bookmark, relativePath: "img.png", isVideo: false, maxPixelSize: 64) != nil)
        let fp = try #require(fileURL.contentFingerprint())
        #expect(FileManager.default.fileExists(atPath: cacheDir.appending(path: "\(fp).heic").path))

        // A model that carries the fingerprint drives the entry point; the same name is formed and
        // the existing `.heic` is served.
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .image)
        let file = PlaylistFile(relativePath: "img.png", fileName: "img.png")
        file.fingerprint = fp
        let result = await service.thumbnail(for: file, in: playlist, maxPixelSize: 64)
        #expect(result.image != nil)                 // disk hit via the supplied fingerprint
        #expect(result.metadata.fingerprint == nil)  // supplied → nothing re-reported to persist
    }

    /// A file whose bytes can't be opened has no fingerprint, so the produce path forms no cache
    /// name: it yields no thumbnail and writes nothing to the cache directory.
    @Test
    func unreadableFileYieldsNoThumbnailAndNoCacheEntry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let fileURL = dir.appending(path: "locked.png")
        try writePNG(width: 40, height: 40, to: fileURL)
        // Strip read permission so the bytes can't be opened for fingerprinting (owner included).
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)

        let service = await ThumbnailService(cacheDirectory: cacheDir)
        let data = await service.thumbnailData(bookmark: bookmark, relativePath: "locked.png", isVideo: false, maxPixelSize: 64)
        #expect(data == nil)                                  // no fingerprint → no thumbnail
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(entries.isEmpty)                              // the cache is untouched
    }

    // MARK: - Cache management

    /// The reported size sums the `.heic` thumbnails and nothing else — a stray non-`.heic`
    /// file in the directory doesn't inflate it.
    @Test
    func cacheSizeSumsOnlyHeicFiles() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        try Data(count: 100).write(to: cacheDir.appending(path: "aaa.heic"))
        try Data(count: 250).write(to: cacheDir.appending(path: "bbb.heic"))
        try Data(count: 999).write(to: cacheDir.appending(path: "notes.txt"))

        let service = await ThumbnailService(cacheDirectory: cacheDir)
        #expect(await service.cacheSize() == 350)
    }

    /// Clear-all empties the cache: every thumbnail is gone and the reported size drops to zero.
    @Test
    func clearCacheEmptiesTheDirectory() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        try Data(count: 100).write(to: cacheDir.appending(path: "aaa.heic"))
        try Data(count: 100).write(to: cacheDir.appending(path: "bbb.heic"))

        let service = await ThumbnailService(cacheDirectory: cacheDir)
        await service.clearCache()

        #expect(await service.cacheSize() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).isEmpty)
    }

    /// Clear-orphans removes exactly the thumbnails whose fingerprint no live record carries and
    /// keeps the referenced ones, reporting the count and total bytes it freed.
    @Test
    func clearOrphansRemovesUnreferencedKeepsReferenced() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        try Data(count: 100).write(to: cacheDir.appending(path: "aaa.heic"))
        try Data(count: 500).write(to: cacheDir.appending(path: "bbb.heic"))   // orphan
        try Data(count: 100).write(to: cacheDir.appending(path: "ccc.heic"))

        let service = await ThumbnailService(cacheDirectory: cacheDir)
        let result = await service.clearOrphans(liveFingerprints: ["aaa", "ccc"])

        #expect(result.removed == 1)
        #expect(result.bytes == 500)
        #expect(FileManager.default.fileExists(atPath: cacheDir.appending(path: "aaa.heic").path))
        #expect(FileManager.default.fileExists(atPath: cacheDir.appending(path: "ccc.heic").path))
        #expect(!FileManager.default.fileExists(atPath: cacheDir.appending(path: "bbb.heic").path))
    }
}
