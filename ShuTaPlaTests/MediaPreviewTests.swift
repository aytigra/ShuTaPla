//
//  MediaPreviewTests.swift
//  ShuTaPlaTests
//
//  The Manager "peek": open/close/toggle, the per-type engine choice, and the
//  video preview's loop / playlist-volume / from-the-beginning load.
//
//  Like the coordinator tests, the video slot is filled with the window-free
//  `AudioPlaybackEngine` (via the engine factory) so no Vulkan surface is created,
//  and folders are real temp directories with empty placeholder files — every
//  assertion is on the preview's synchronous bookkeeping, not on decoded output.
//  `source` is left nil on the preview engine, so an empty file's `END_FILE` never
//  advances into torn-down models.
//

import Testing
import Foundation
import CoreGraphics
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct MediaPreviewTests {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files { try Data().write(to: url.appending(path: name)) }
        let bookmark = try BookmarkService.makeBookmark(for: url)
        return (url, bookmark)
    }

    @discardableResult
    private func makePlaylist(
        _ type: MediaType, folder: (url: URL, bookmark: Data),
        files: [String], in context: ModelContext
    ) -> Playlist {
        let playlist = Playlist(
            name: type.rawValue, folderBookmark: folder.bookmark,
            folderPath: folder.url.path(percentEncoded: false), mediaType: type
        )
        context.insert(playlist)
        for (index, name) in files.enumerated() {
            let file = PlaylistFile(relativePath: name, fileName: name, sortOrder: index)
            file.playlist = playlist
            context.insert(file)
        }
        try? context.save()
        return playlist
    }

    /// A preview whose video slot uses the window-free audio engine, so no libmpv video
    /// surface is created in the test host.
    private func makePreview(_ folderAccess: ScopedFolderAccess) -> MediaPreview {
        MediaPreview(folderAccess: folderAccess, makeVideoEngine: { try AudioPlaybackEngine() })
    }

    /// Records the resume position each `load` is asked to start at, so a test can assert the
    /// preview loads from the beginning (nil).
    @MainActor
    private final class RecordingLoadEngine: MPVPlaybackEngine {
        private(set) var loadedPositions: [TimeInterval?] = []
        init() throws { try super.init(configuration: .audio) }
        override func load(_ file: PlaylistFile?, resource: String, startingAt position: TimeInterval?) {
            loadedPositions.append(position)
            super.load(file, resource: resource, startingAt: position)
        }
    }

    // MARK: - Open / close / toggle

    @Test func toggleOpensThenCloses() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let file = image.files[0]

        let preview = makePreview(ScopedFolderAccess(bookmarkService: BookmarkService()))
        defer { preview.shutdown() }

        #expect(!preview.isOpen)
        preview.toggle(file)
        #expect(preview.isOpen)
        #expect(preview.file === file)
        #expect(preview.mediaType == .image)

        preview.toggle(file)
        #expect(!preview.isOpen)
        #expect(preview.file == nil)
    }

    @Test func imagePreviewLoadsTheFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let file = image.files[0]

        let preview = makePreview(ScopedFolderAccess(bookmarkService: BookmarkService()))
        defer { preview.shutdown() }

        preview.toggle(file)
        #expect(preview.imageEngine.currentFile === file)   // set synchronously by load
        #expect(preview.videoEngine == nil)                 // image path never spins up libmpv
    }

    @Test func videoPreviewLoopsAtPlaylistVolumeFromTheBeginning() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4"])
        let video = makePlaylist(.video, folder: folder, files: ["v.mp4"], in: context)
        video.preferences.volume = 0.4
        try context.save()
        let file = video.files[0]

        let recorder = try RecordingLoadEngine()
        let preview = MediaPreview(
            folderAccess: ScopedFolderAccess(bookmarkService: BookmarkService()),
            makeVideoEngine: { recorder }
        )
        defer { preview.shutdown() }

        preview.toggle(file)
        #expect(preview.videoEngine?.isLooping == true)             // loops forever
        #expect(abs((preview.videoEngine?.volume ?? 0) - 40) < 0.001)   // playlist volume (0.4 → 40)
        #expect(recorder.loadedPositions.last == .some(nil))        // from the beginning
    }

    // MARK: - Scoped session

    @Test func closeReleasesTheScopedSession() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let file = image.files[0]

        let folderAccess = ScopedFolderAccess(bookmarkService: BookmarkService())
        let preview = makePreview(folderAccess)
        defer { preview.shutdown() }

        preview.toggle(file)
        #expect(folderAccess.url(for: image.id) != nil)     // session open during the preview
        preview.close()
        #expect(folderAccess.url(for: image.id) == nil)     // released on close
    }

    // MARK: - Video dimensions (card aspect ratio)

    @Test func videoSizeTracksDwidthDheightEvents() throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }

        #expect(engine.videoSize == .zero)
        engine.handle(.videoWidth(1920))
        engine.handle(.videoHeight(1080))
        #expect(engine.videoSize == CGSize(width: 1920, height: 1080))

        engine.handle(.videoWidth(nil))     // no video decoded clears the width
        #expect(engine.videoSize.width == 0)
    }

    @Test func videoContentSizeAppearsOnceDimensionsAreKnown() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4"])
        let video = makePlaylist(.video, folder: folder, files: ["v.mp4"], in: context)
        let file = video.files[0]

        let preview = makePreview(ScopedFolderAccess(bookmarkService: BookmarkService()))
        defer { preview.shutdown() }

        preview.toggle(file)
        #expect(preview.contentSize == nil)                   // no dimensions yet → the card waits
        preview.videoEngine?.handle(.videoWidth(1280))
        preview.videoEngine?.handle(.videoHeight(720))
        #expect(preview.contentSize == CGSize(width: 1280, height: 720))

        preview.videoEngine?.handle(.videoHeight(0))          // a zero dimension is not a real shape
        #expect(preview.contentSize == nil)
    }

    // MARK: - Gating

    @Test func audioIsNeverPreviewed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["a.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: ["a.mp3"], in: context)
        let file = audio.files[0]

        let preview = makePreview(ScopedFolderAccess(bookmarkService: BookmarkService()))
        defer { preview.shutdown() }

        preview.toggle(file)
        #expect(!preview.isOpen)   // audio is played inline in Manager; it has no preview
    }
}
