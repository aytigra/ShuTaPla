//
//  MediaMetadataServiceTests.swift
//  ShuTaPlaTests
//
//  Media-metadata extraction for the Manager's list mode: running time, pixel
//  dimensions, and on-disk size. The stateless `extract` resolves a file and reads
//  its metadata (AVFoundation first, libmpv fallback for video; `CGImageSource` for
//  stills); the model-facing `metadata(for:in:)` serves a cached bundle without
//  re-reading and folds a freshly extracted one onto the model. Real codec-labeled
//  samples in `test_media/videos` back the video paths; a synthesized PNG backs the
//  image path.
//

import Testing
import Foundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import ShuTaPla

@Suite struct MediaMetadataServiceTests {

    /// `test_media/videos`, two levels up from this test file (the repo root).
    private static var videosDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "test_media/videos", directoryHint: .isDirectory)
    }

    /// The first sample whose filename starts with `prefix`.
    private static func sample(prefix: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: videosDirectory, includingPropertiesForKeys: nil
        )
        return try #require(
            files.first { $0.lastPathComponent.hasPrefix(prefix) },
            "no sample with prefix \(prefix) in \(videosDirectory.path)"
        )
    }

    /// Writes a `width`×`height` PNG into a fresh temp directory; the directory is the
    /// caller's to remove when the test ends.
    private static func makeImage(width: Int, height: Int) throws -> (directory: URL, fileName: String) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MetadataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "image.png")
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (directory, "image.png")
    }

    /// A fresh in-memory container with the full app schema.
    @MainActor private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Stateless extraction

    @Test func extractReturnsEmptyForMissingFile() async throws {
        let bookmark = try BookmarkService.makeBookmark(for: Self.videosDirectory)
        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: "does-not-exist.mp4", mediaType: .video
        )
        #expect(metadata.duration == nil)
        #expect(metadata.width == nil)
        #expect(metadata.height == nil)
        #expect(metadata.fileSizeBytes == nil)
    }

    // h264 takes the AVFoundation path; vp9 falls back to libmpv. Either way the whole
    // chain reports a positive duration, positive display dimensions (the libmpv case
    // confirms `dwidth`/`dheight` populate at `FILE_LOADED` under `vo=null` for webm),
    // and the on-disk size.
    @Test(arguments: ["h264", "vp9"])
    func extractReadsVideoMetadata(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)
        let bookmark = try BookmarkService.makeBookmark(for: url.deletingLastPathComponent())
        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: url.lastPathComponent, mediaType: .video
        )
        #expect(try #require(metadata.duration) > 0)
        #expect(try #require(metadata.width) > 0)
        #expect(try #require(metadata.height) > 0)
        #expect(try #require(metadata.fileSizeBytes) > 0)
    }

    // A still reports its header pixel size (no pixel decode) and on-disk size, and no
    // duration.
    @Test func extractReadsImagePixelSizeAndFileSize() async throws {
        let (directory, fileName) = try Self.makeImage(width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try BookmarkService.makeBookmark(for: directory)

        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: fileName, mediaType: .image
        )
        #expect(metadata.width == 64)
        #expect(metadata.height == 48)
        #expect(metadata.duration == nil)
        #expect(try #require(metadata.fileSizeBytes) > 0)
    }

    // MARK: - The merge sink

    @MainActor @Test func mergeFillsOnlyNilFields() throws {
        let file = PlaylistFile(relativePath: "a.mp4", fileName: "a.mp4")
        file.duration = 10          // already known — must survive the merge
        file.width = 1920
        file.fingerprint = "keepme" // already known — must survive the merge

        file.merge(MediaMetadata(duration: 99, width: 640, height: 480, fileSizeBytes: 2048, fingerprint: "other"))

        #expect(file.duration == 10)          // untouched
        #expect(file.width == 1920)           // untouched
        #expect(file.height == 480)           // filled
        #expect(file.fileSizeBytes == 2048)   // filled
        #expect(file.fingerprint == "keepme") // untouched

        // A record with no fingerprint yet takes the merged one — the first-display path persisting.
        let fresh = PlaylistFile(relativePath: "b.mp4", fileName: "b.mp4")
        fresh.merge(MediaMetadata(fingerprint: "abc"))
        #expect(fresh.fingerprint == "abc")
    }

    // MARK: - The completeness guard

    @MainActor @Test func completenessGuardIsTypeAware() throws {
        let file = PlaylistFile(relativePath: "a", fileName: "a")
        file.fileSizeBytes = 1

        // Video needs duration + dimensions; audio only duration; image only dimensions.
        file.duration = 5
        #expect(!file.hasCompleteMetadata(for: .video))   // dimensions missing
        #expect(file.hasCompleteMetadata(for: .audio))    // duration + size suffice
        file.width = 320
        file.height = 240
        #expect(file.hasCompleteMetadata(for: .video))
        #expect(file.hasCompleteMetadata(for: .image))

        // Size is required for every type.
        file.fileSizeBytes = nil
        #expect(!file.hasCompleteMetadata(for: .audio))
        #expect(!file.hasCompleteMetadata(for: .image))
    }

    // MARK: - Model-facing caching

    @MainActor @Test func completeMetadataReturnedWithoutExtraction() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        // An empty bookmark can't resolve, so extraction would yield an empty bundle — the
        // cached values coming back prove the guard short-circuited before any read.
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        let file = PlaylistFile(relativePath: "missing.mp4", fileName: "missing.mp4")
        file.duration = 123.5
        file.width = 1280
        file.height = 720
        file.fileSizeBytes = 4096
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        let metadata = await MediaMetadataService().metadata(for: file, in: playlist)
        #expect(metadata.duration == 123.5)
        #expect(metadata.width == 1280)
        #expect(metadata.height == 720)
        #expect(metadata.fileSizeBytes == 4096)

        _ = container
    }

    @MainActor @Test func extractsAndCachesOnModel() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let url = try Self.sample(prefix: "h264")
        let dir = url.deletingLastPathComponent()
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "V", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        let file = PlaylistFile(relativePath: url.lastPathComponent, fileName: url.lastPathComponent)
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        let metadata = await MediaMetadataService().metadata(for: file, in: playlist)
        #expect(try #require(metadata.duration) > 0)
        #expect(try #require(metadata.width) > 0)
        #expect(try #require(metadata.height) > 0)
        #expect(try #require(metadata.fileSizeBytes) > 0)
        // Written back onto the model.
        #expect(file.duration == metadata.duration)
        #expect(file.pixelSize == CGSize(width: metadata.width!, height: metadata.height!))
        #expect(file.fileSizeBytes == metadata.fileSizeBytes)

        _ = container
    }

    // Incidental healing: a file already carrying its duration but missing the newer
    // fields fills the gaps on its next display, without disturbing the known value.
    @MainActor @Test func healsMissingFieldsOnDisplay() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let url = try Self.sample(prefix: "h264")
        let dir = url.deletingLastPathComponent()
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "V", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        let file = PlaylistFile(relativePath: url.lastPathComponent, fileName: url.lastPathComponent)
        file.duration = 7          // a pre-existing cached length, dimensions/size still nil
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        _ = await MediaMetadataService().metadata(for: file, in: playlist)
        #expect(file.duration == 7)                       // untouched
        #expect(try #require(file.width) > 0)             // healed
        #expect(try #require(file.height) > 0)
        #expect(try #require(file.fileSizeBytes) > 0)

        _ = container
    }
}
