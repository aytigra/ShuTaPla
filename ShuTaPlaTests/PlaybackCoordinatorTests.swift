//
//  PlaybackCoordinatorTests.swift
//  ShuTaPlaTests
//
//  Task 11 — the coordinator's orchestration: channel exclusivity (video XOR
//  image, plus independent audio), suppression resume semantics, and the
//  wrap-around playback order it exposes as a `PlaybackSource`.
//
//  Channel exclusivity and suppression run real engines, but the video slot is
//  filled with the window-free `AudioPlaybackEngine` (injected via the engine
//  factory) so no Vulkan surface is created in the test host. The folders are real
//  temp directories with a plain bookmark, so scoped access resolves; the files
//  needn't decode because every assertion is on the coordinator's synchronous
//  bookkeeping (active playlist, persisted state, suppression), not on mpv output.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct PlaybackCoordinatorTests {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A temp directory holding the named (empty) files, and a bookmark to it.
    private func makeFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files { try Data().write(to: url.appending(path: name)) }
        let bookmark = try BookmarkService.makeBookmark(for: url)
        return (url, bookmark)
    }

    @discardableResult
    private func makePlaylist(
        _ type: MediaType,
        folder: (url: URL, bookmark: Data),
        files: [(name: String, tags: [String])],
        in context: ModelContext
    ) -> Playlist {
        let playlist = Playlist(
            name: type.rawValue, folderBookmark: folder.bookmark,
            folderPath: folder.url.path(percentEncoded: false), mediaType: type
        )
        context.insert(playlist)
        for (index, file) in files.enumerated() {
            let model = PlaylistFile(
                relativePath: file.name, fileName: file.name,
                tags: file.tags, taggingStatus: file.tags.isEmpty ? .untagged : .valid,
                sortOrder: index
            )
            model.playlist = playlist
            context.insert(model)
        }
        return playlist
    }

    /// A coordinator whose mpv channels use the window-free audio engine.
    private func makeCoordinator(_ bookmarks: BookmarkService) -> PlaybackCoordinator {
        PlaybackCoordinator(
            bookmarkService: bookmarks,
            makeVideoEngine: { try AudioPlaybackEngine() },
            makeAudioEngine: { try AudioPlaybackEngine() }
        )
    }

    // MARK: - Channel exclusivity

    @Test func startingVisualPlaylistStopsTheOther() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4", "i.jpg"])
        let video = makePlaylist(.video, folder: folder, files: [("v.mp4", [])], in: context)
        let image = makePlaylist(.image, folder: folder, files: [("i.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(video)
        #expect(coordinator.visualPlaylist === video)
        #expect(coordinator.visualKind == .video)
        #expect(video.playbackState == .playing)

        coordinator.play(image)
        #expect(coordinator.visualPlaylist === image)
        #expect(coordinator.visualKind == .image)
        #expect(image.playbackState == .playing)
        #expect(video.playbackState == .stopped)   // the visual channel is shared
    }

    @Test func audioRunsAlongsideVisual() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4", "a.mp3"])
        let video = makePlaylist(.video, folder: folder, files: [("v.mp4", [])], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: [("a.mp3", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(video)
        coordinator.play(audio)

        #expect(coordinator.visualPlaylist === video)
        #expect(coordinator.audioPlaylist === audio)
        #expect(video.playbackState == .playing)
        #expect(audio.playbackState == .playing)
    }

    // MARK: - Suppression

    @Test func suppressHaltsBothChannelsWithoutChangingStates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4", "a.mp3"])
        let video = makePlaylist(.video, folder: folder, files: [("v.mp4", [])], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: [("a.mp3", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }
        coordinator.play(video)
        coordinator.play(audio)

        coordinator.suppress()
        #expect(coordinator.isSuppressed)
        #expect(video.playbackState == .playing)   // states untouched by suppression
        #expect(audio.playbackState == .playing)

        coordinator.unsuppress()
        #expect(!coordinator.isSuppressed)
        #expect(video.playbackState == .playing)
        #expect(audio.playbackState == .playing)
    }

    @Test func unsuppressResumesPlayingButNotPaused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4", "a.mp3"])
        let video = makePlaylist(.video, folder: folder, files: [("v.mp4", [])], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: [("a.mp3", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }
        coordinator.play(video)
        coordinator.play(audio)
        coordinator.pause(video)                    // video paused on its own
        #expect(video.playbackState == .paused)

        coordinator.suppress()
        coordinator.unsuppress()

        #expect(video.playbackState == .paused)     // its own Paused survives
        #expect(audio.playbackState == .playing)    // Playing resumes
    }

    // MARK: - Wrap-around order (PlaybackSource)

    @Test func advanceAndPreviousWrapAround() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp4", "2.mp4", "3.mp4"])
        let playlist = makePlaylist(
            .video, folder: folder,
            files: [("1.mp4", []), ("2.mp4", []), ("3.mp4", [])], in: context
        )
        try context.save()
        let files = playlist.playbackSequence
        #expect(files.count == 3)

        let coordinator = makeCoordinator(BookmarkService())
        #expect(coordinator.fileAfter(files[0]) === files[1])
        #expect(coordinator.fileAfter(files[2]) === files[0])    // past the last → first
        #expect(coordinator.fileBefore(files[0]) === files[2])   // before the first → last
        #expect(coordinator.fileBefore(files[1]) === files[0])
    }

    @Test func wrapFollowsTheActiveFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp4", "2.mp4", "3.mp4"])
        let playlist = makePlaylist(
            .video, folder: folder,
            files: [("1.mp4", ["beach"]), ("2.mp4", ["city"]), ("3.mp4", ["beach"])], in: context
        )
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and)
        try context.save()

        let sequence = playlist.playbackSequence
        #expect(sequence.map(\.fileName) == ["1.mp4", "3.mp4"])   // city file filtered out

        let coordinator = makeCoordinator(BookmarkService())
        #expect(coordinator.fileAfter(sequence[0]) === sequence[1])
        #expect(coordinator.fileAfter(sequence[1]) === sequence[0])   // wraps within matches
    }
}
