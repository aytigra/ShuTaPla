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
            bookmark: bookmark, relativePath: "does-not-exist.mp4", mediaType: .video, isSkipped: false
        )
        #expect(metadata.duration == nil)
        #expect(metadata.width == nil)
        #expect(metadata.height == nil)
        #expect(metadata.fileSizeBytes == nil)
        #expect(metadata.lastModified == nil)
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
            bookmark: bookmark, relativePath: url.lastPathComponent, mediaType: .video, isSkipped: false
        )
        #expect(try #require(metadata.duration) > 0)
        #expect(try #require(metadata.width) > 0)
        #expect(try #require(metadata.height) > 0)
        #expect(try #require(metadata.fileSizeBytes) > 0)
        #expect(metadata.lastModified != nil)   // the baseline for staleness, read on every open
    }

    // A still reports its header pixel size (no pixel decode) and on-disk size, and no
    // duration.
    @Test func extractReadsImagePixelSizeAndFileSize() async throws {
        let (directory, fileName) = try Self.makeImage(width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try BookmarkService.makeBookmark(for: directory)

        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: fileName, mediaType: .image, isSkipped: false
        )
        #expect(metadata.width == 64)
        #expect(metadata.height == 48)
        #expect(metadata.duration == nil)
        #expect(try #require(metadata.fileSizeBytes) > 0)
        #expect(metadata.lastModified != nil)
    }

    // A skipped file is wrong-type for its playlist, so the type decoder can't read it. `extract`
    // records only the on-disk size and skips the decode entirely — no duration, no dimensions —
    // even for a real video that would otherwise decode fully.
    @Test func extractReadsOnlySizeForSkippedFile() async throws {
        let url = try Self.sample(prefix: "h264")
        let bookmark = try BookmarkService.makeBookmark(for: url.deletingLastPathComponent())
        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: url.lastPathComponent, mediaType: .video, isSkipped: true
        )
        #expect(metadata.duration == nil)
        #expect(metadata.width == nil)
        #expect(metadata.height == nil)
        #expect(try #require(metadata.fileSizeBytes) > 0)
        #expect(metadata.lastModified != nil)   // mtime is read before the skip guard, so even a skip gets a baseline
    }

    // A pre-resolved folder URL — the one scoped-access session a file surface holds open for the
    // browsed folder — is appended to directly, so the per-file bookmark resolve is skipped. A
    // deliberately unresolvable bookmark proves the folder path never touches it: with `folderURL`
    // supplied the metadata comes back; with it `nil` the same call resolves the bad bookmark and
    // reads nothing.
    @Test func preResolvedFolderBypassesPerFileBookmarkResolution() async throws {
        let (directory, fileName) = try Self.makeImage(width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unresolvable = Data("not-a-bookmark".utf8)

        let viaFolder = await MediaMetadataService.extract(
            folderURL: directory, bookmark: unresolvable, relativePath: fileName, mediaType: .image, isSkipped: false
        )
        #expect(viaFolder.width == 64)       // read via the pre-resolved folder, no per-file resolve
        #expect(viaFolder.height == 48)

        let viaBookmark = await MediaMetadataService.extract(
            folderURL: nil, bookmark: unresolvable, relativePath: fileName, mediaType: .image, isSkipped: false
        )
        #expect(viaBookmark.width == nil)    // no folder → the bad bookmark can't resolve, nothing read
    }

    // MARK: - The merge sink

    @MainActor @Test func mergeCoalescesNonNilFields() throws {
        let file = PlaylistFile(relativePath: "a.mp4", fileName: "a.mp4")
        file.duration = 10
        file.width = 1920
        file.fingerprint = "old"
        file.lastModified = Date(timeIntervalSince1970: 1)

        // A bundle carrying every field (a fresh render / size-mismatch re-derivation) overwrites —
        // a freshly-read value always wins over a stale cached one.
        file.merge(MediaMetadata(duration: 99, width: 640, height: 480, fileSizeBytes: 2048,
                                 fingerprint: "new", lastModified: Date(timeIntervalSince1970: 2)))
        #expect(file.duration == 99)          // overwritten by the fresh read
        #expect(file.width == 640)            // overwritten
        #expect(file.height == 480)           // filled
        #expect(file.fileSizeBytes == 2048)   // filled
        #expect(file.fingerprint == "new")    // overwritten
        #expect(file.lastModified == Date(timeIntervalSince1970: 2))   // overwritten

        // A partial bundle (a disk-cache hit: size + fingerprint + mtime, no decode) leaves the
        // decoded fields intact — a `nil` means "not read", never erases what's cached.
        file.merge(MediaMetadata(fileSizeBytes: 4096, fingerprint: "newer",
                                 lastModified: Date(timeIntervalSince1970: 3)))
        #expect(file.duration == 99)          // nil incoming → untouched
        #expect(file.width == 640)            // untouched
        #expect(file.height == 480)           // untouched
        #expect(file.fileSizeBytes == 4096)   // overwritten
        #expect(file.fingerprint == "newer")  // overwritten
        #expect(file.lastModified == Date(timeIntervalSince1970: 3))   // overwritten

        // A bundle that didn't read the mtime (`nil`) leaves the cached one intact.
        file.merge(MediaMetadata(width: 100))
        #expect(file.lastModified == Date(timeIntervalSince1970: 3))   // nil incoming → untouched
    }

    // MARK: - The invalidation primitive

    /// A file carrying every cached fact.
    @MainActor private func fullyCachedFile(size: Int, modified: Date) -> PlaylistFile {
        let file = PlaylistFile(relativePath: "a", fileName: "a")
        file.duration = 10
        file.width = 1920
        file.height = 1080
        file.fileSizeBytes = size
        file.lastModified = modified
        file.fingerprint = "fp"
        return file
    }

    @MainActor @Test func invalidateMetadataClearsEveryField() throws {
        let file = fullyCachedFile(size: 100, modified: Date(timeIntervalSince1970: 1))
        file.invalidateMetadata()
        #expect(file.duration == nil)
        #expect(file.width == nil)
        #expect(file.height == nil)
        #expect(file.fileSizeBytes == nil)
        #expect(file.lastModified == nil)
        #expect(file.fingerprint == nil)     // written directly, so the record truly forgets
    }

    // The staleness gate clears the cache when the on-disk size or mtime diverges from the baseline,
    // and leaves it intact when both match.
    @MainActor @Test func invalidateIfStaleClearsOnDivergenceKeepsOnMatch() throws {
        let modified = Date(timeIntervalSince1970: 1)

        // A diverging size clears everything.
        let bySize = fullyCachedFile(size: 100, modified: modified)
        #expect(bySize.invalidateMetadataIfStale(size: 200, modified: modified))
        #expect(bySize.fileSizeBytes == nil)
        #expect(bySize.duration == nil)

        // A diverging mtime clears everything.
        let byMtime = fullyCachedFile(size: 100, modified: modified)
        #expect(byMtime.invalidateMetadataIfStale(size: 100, modified: Date(timeIntervalSince1970: 2)))
        #expect(byMtime.lastModified == nil)
        #expect(byMtime.fingerprint == nil)

        // A matching pair is a no-op — the facts survive.
        let match = fullyCachedFile(size: 100, modified: modified)
        #expect(!match.invalidateMetadataIfStale(size: 100, modified: modified))
        #expect(match.fileSizeBytes == 100)
        #expect(match.duration == 10)
        #expect(match.fingerprint == "fp")
    }

    // No baseline (`lastModified == nil`) → nothing to invalidate, even against wildly different
    // on-disk values: a file first seen only in gallery-less list mode before S1, or a fresh row.
    @MainActor @Test func invalidateIfStaleNoOpWithoutBaseline() throws {
        let file = PlaylistFile(relativePath: "a", fileName: "a")
        file.fileSizeBytes = 50   // a stray size but no mtime baseline
        #expect(!file.invalidateMetadataIfStale(size: 999, modified: Date()))
        #expect(file.fileSizeBytes == 50)   // untouched
    }

    // An unreadable fact (`nil` from a failed stat) never fires the gate on a false divergence.
    @MainActor @Test func invalidateIfStaleIgnoresUnreadableFacts() throws {
        let modified = Date(timeIntervalSince1970: 1)
        let file = fullyCachedFile(size: 100, modified: modified)
        #expect(!file.invalidateMetadataIfStale(size: nil, modified: nil))
        #expect(file.fileSizeBytes == 100)
        #expect(file.lastModified == modified)
    }

    // MARK: - The completeness guard

    @MainActor @Test func completenessGuardIsTypeAware() throws {
        let file = PlaylistFile(relativePath: "a", fileName: "a")
        file.fileSizeBytes = 1
        file.lastModified = Date()   // the staleness baseline, required for every type

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

    // The staleness baseline (`lastModified`) is required for every type: a pre-mtime cached row —
    // every field but the mtime present — reads incomplete, so its next display re-extracts and
    // gains a baseline for the scan/preview to compare against.
    @MainActor @Test func metadataIncompleteWithoutLastModified() throws {
        let file = PlaylistFile(relativePath: "a", fileName: "a")
        file.fileSizeBytes = 1
        file.duration = 5
        file.width = 320
        file.height = 240
        #expect(!file.hasCompleteMetadata(for: .video))    // no mtime → incomplete despite full facts
        #expect(!file.hasCompleteMetadata(for: .audio))
        #expect(!file.hasCompleteMetadata(for: .image))

        file.lastModified = Date()
        #expect(file.hasCompleteMetadata(for: .video))     // baseline present → complete
    }

    // A skipped file is wrong-type for its playlist, so its duration/dimensions can never be read;
    // only size is ever recorded for it. It is complete the moment the size is known — otherwise the
    // metadata service would re-open it on every display forever, chasing fields it can't obtain.
    @MainActor @Test func skippedFileCompleteOnceSized() throws {
        let file = PlaylistFile(relativePath: "a", fileName: "a")
        file.isSkipped = true

        #expect(!file.hasCompleteMetadata(for: .video))   // no size yet → still incomplete
        file.fileSizeBytes = 1
        #expect(!file.hasCompleteMetadata(for: .video))   // still missing the mtime baseline
        file.lastModified = Date()
        #expect(file.hasCompleteMetadata(for: .video))     // size + baseline complete it, despite no duration/dims
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
        file.lastModified = Date()   // baseline present, so the completeness guard short-circuits the read
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

    // The service saves after merging, so the freshly extracted facts are durable the moment they
    // land: no pending in-memory edits for a later `includePendingChanges = false` object fetch to
    // refault away (the fresh-vs-relaunch blanking that S4 traces to unsaved metadata).
    @MainActor @Test func extractedMetadataIsPersisted() async throws {
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

        _ = await MediaMetadataService().metadata(for: file, in: playlist)
        #expect(!context.hasChanges)   // the merge was flushed to the store

        _ = container
    }

    // A file carrying a partial bundle fills its missing fields on its next display; because a
    // freshly-read value wins (coalesce-non-nil merge), its pre-existing duration is refreshed from
    // the file too, rather than a stale seeded value surviving.
    @MainActor @Test func fillsGapsAndRefreshesOnDisplay() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let url = try Self.sample(prefix: "h264")
        let dir = url.deletingLastPathComponent()
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "V", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        let file = PlaylistFile(relativePath: url.lastPathComponent, fileName: url.lastPathComponent)
        file.duration = 7          // a seeded (stale) length, dimensions/size still nil → incomplete
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        _ = await MediaMetadataService().metadata(for: file, in: playlist)
        #expect(try #require(file.duration) > 0)          // refreshed from the file (not the seeded 7)
        #expect(file.duration != 7)
        #expect(try #require(file.width) > 0)             // filled
        #expect(try #require(file.height) > 0)
        #expect(try #require(file.fileSizeBytes) > 0)

        _ = container
    }

    // MARK: - Cloud-aware extraction

    /// An evicted file (`cloudStatus != .local`) is not opened — extracting would read bytes that
    /// aren't local — so the model-facing entry point returns the (here empty) cached bundle and
    /// leaves the model untouched, even though the file is readable on disk.
    @MainActor @Test func evictedFileSkipsExtractionAndReturnsCached() async throws {
        let (directory, fileName) = try Self.makeImage(width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try BookmarkService.makeBookmark(for: directory)

        let playlist = Playlist(name: "I", folderBookmark: bookmark, folderPath: directory.path, mediaType: .image)
        let file = PlaylistFile(relativePath: fileName, fileName: fileName)
        file.cloudStatus = .inCloud

        let metadata = await MediaMetadataService().metadata(for: file, in: playlist)
        #expect(metadata.width == nil)          // no extraction ran
        #expect(metadata.height == nil)
        #expect(metadata.fileSizeBytes == nil)
        #expect(file.fileSizeBytes == nil)      // the model is untouched
    }
}
