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

    // MARK: - Player controls surface (Task 14)

    @Test func setVolumePersistsAndClamps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["i.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("i.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.setVolume(image, to: 0.4)
        #expect(abs(coordinator.playbackVolume(for: image) - 0.4) < 0.0001)
        coordinator.setVolume(image, to: 1.5)             // above range
        #expect(image.preferences.volume == 1.0)
        coordinator.setVolume(image, to: -0.2)            // below range
        #expect(image.preferences.volume == 0.0)
    }

    @Test func slideshowPreferencesPersist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["i.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("i.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        // Not the active visual channel, so no live timer starts — only the preference.
        coordinator.setSlideshowEnabled(image, true)
        #expect(image.preferences.slideshowEnabled)
        coordinator.setSlideshowInterval(image, 12)
        #expect(image.preferences.slideshowInterval == 12)
    }

    @Test func reconcileJumpsWhenCurrentFileFilteredOut() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg", "3.jpg"])
        let image = makePlaylist(
            .image, folder: folder,
            files: [("1.jpg", ["a"]), ("2.jpg", ["b"]), ("3.jpg", ["b"])], in: context
        )
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        let firstID = coordinator.visualCurrentFile?.id

        // Filter to "b" — the playing "1.jpg" (tagged "a") is excluded, so reconciling
        // jumps to the first file that still matches.
        image.filterState = FilterState(selectedTags: ["b"], filterMode: .or)
        coordinator.reconcileVisualSelection()

        let matching = image.playbackSequence
        #expect(matching.map(\.fileName) == ["2.jpg", "3.jpg"])
        #expect(coordinator.visualCurrentFile?.id == matching.first?.id)
        #expect(coordinator.visualCurrentFile?.id != firstID)
    }

    @Test func reconcileKeepsCurrentFileWhenStillMatching() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(
            .image, folder: folder,
            files: [("1.jpg", ["a"]), ("2.jpg", ["b"])], in: context
        )
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        let currentID = coordinator.visualCurrentFile?.id

        // The playing file still matches the new filter, so reconciling leaves it put.
        image.filterState = FilterState(selectedTags: ["a"], filterMode: .or)
        coordinator.reconcileVisualSelection()
        #expect(coordinator.visualCurrentFile?.id == currentID)
    }

    @Test func reconcileClearsCurrentFileWhenSequenceEmpties() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(
            .image, folder: folder,
            files: [("1.jpg", ["a"]), ("2.jpg", ["a"])], in: context
        )
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        #expect(coordinator.visualCurrentFile != nil)

        // A filter that matches nothing empties the sequence. The channel stays set (so the
        // player shows its "no files" placeholder), but the engine's current file is cleared
        // so a later advance/seek can't act on a file no longer in the playlist.
        image.filterState = FilterState(selectedTags: ["nonexistent"], filterMode: .or)
        coordinator.reconcileVisualSelection()

        #expect(image.playbackSequence.isEmpty)
        #expect(coordinator.visualPlaylist === image)   // still in Player mode
        #expect(coordinator.visualCurrentFile == nil)   // but no stale current file
    }

    @Test func shutdownResetsChannelBookkeeping() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["v.mp4", "a.mp3"])
        let video = makePlaylist(.video, folder: folder, files: [("v.mp4", [])], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: [("a.mp3", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        coordinator.play(video)
        coordinator.play(audio)
        coordinator.suppress()

        coordinator.shutdown()

        #expect(coordinator.visualPlaylist == nil)
        #expect(coordinator.visualKind == nil)
        #expect(coordinator.audioPlaylist == nil)
        #expect(!coordinator.isSuppressed)
        #expect(!coordinator.visualHaltedForOverlay)
    }

    @Test func togglePauseFlipsBetweenPlayingAndPaused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("1.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        #expect(image.playbackState == .playing)
        coordinator.togglePause(image)
        #expect(image.playbackState == .paused)
        coordinator.togglePause(image)
        #expect(image.playbackState == .playing)
    }

    @Test func playNowLiftsSuppressionAndJumps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg", "3.jpg"])
        let image = makePlaylist(
            .image, folder: folder,
            files: [("1.jpg", []), ("2.jpg", []), ("3.jpg", [])], in: context
        )
        try context.save()
        let files = image.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        coordinator.suppress()
        #expect(coordinator.isSuppressed)

        coordinator.playNow(image, file: files[2])
        #expect(!coordinator.isSuppressed)                         // global pause lifted
        #expect(image.playbackState == .playing)
        #expect(coordinator.visualCurrentFile?.id == files[2].id)  // jumped to the chosen file
    }

    @Test func playNowClearsTheChannelsOwnPause() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("1.jpg", []), ("2.jpg", [])], in: context)
        try context.save()
        let files = image.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        coordinator.pause(image)
        #expect(image.playbackState == .paused)

        coordinator.playNow(image, file: files[1])
        #expect(image.playbackState == .playing)                   // its own pause cleared
        #expect(coordinator.visualCurrentFile?.id == files[1].id)
    }

    @Test func haltAndResumeVisualForOverlayLeavePersistedStateAlone() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("1.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        coordinator.haltVisualForOverlay()
        #expect(coordinator.visualHaltedForOverlay)
        #expect(image.playbackState == .playing)   // halt is transient; persisted state untouched

        coordinator.resumeVisualForOverlay()
        #expect(!coordinator.visualHaltedForOverlay)
        #expect(image.playbackState == .playing)
    }

    @Test func haltVisualForOverlayIsSkippedWhileSuppressed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("1.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        coordinator.suppress()

        // Suppression already halts the channel, so the overlay-halt is a no-op (nothing to
        // balance later) rather than double-counting the suspend.
        coordinator.haltVisualForOverlay()
        #expect(!coordinator.visualHaltedForOverlay)
    }

    @Test func jumpLoadsRequestedFileOnImageChannel() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg", "3.jpg"])
        let image = makePlaylist(
            .image, folder: folder,
            files: [("1.jpg", []), ("2.jpg", []), ("3.jpg", [])], in: context
        )
        try context.save()
        let files = image.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        coordinator.jump(image, to: files[2])
        #expect(image.currentFileID == files[2].id)
        #expect(coordinator.visualCurrentFile?.id == files[2].id)
    }
}
