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
        #expect(coordinator.liveVisualPlaylist === video)
        #expect(coordinator.visualKind == .video)
        #expect(video.playbackState == .playing)

        coordinator.play(image)
        #expect(coordinator.liveVisualPlaylist === image)
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

        #expect(coordinator.liveVisualPlaylist === video)
        #expect(coordinator.liveAudioPlaylist === audio)
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
        coordinator.setSlideshowInterval(image, nil)        // clearing falls back to the global default
        #expect(image.preferences.slideshowInterval == nil)
    }

    @Test func imageFitModeOverridePersistsAndClears() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["i.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("i.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        #expect(image.preferences.imageFitMode == nil)      // unset → inherits the global default
        coordinator.setImageFitMode(image, .cover)
        #expect(image.preferences.imageFitMode == .cover)
        coordinator.setImageFitMode(image, nil)             // back to inheriting the default
        #expect(image.preferences.imageFitMode == nil)
    }

    @Test func cycleImageFitModeWalksFitCoverOriginalAndPersists() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["i.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("i.jpg", [])], in: context)

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        // Starts from the inherited global default (Fit); each cycle persists the next mode.
        #expect(image.preferences.imageFitMode == nil)
        coordinator.cycleImageFitMode(image)
        #expect(image.preferences.imageFitMode == .cover)
        coordinator.cycleImageFitMode(image)
        #expect(image.preferences.imageFitMode == .original)
        coordinator.cycleImageFitMode(image)
        #expect(image.preferences.imageFitMode == .fit)     // wraps back to the start
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
        coordinator.reconcile(playlistThatChanged: image)

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
        coordinator.reconcile(playlistThatChanged: image)
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
        coordinator.reconcile(playlistThatChanged: image)

        #expect(image.playbackSequence.isEmpty)
        #expect(coordinator.liveVisualPlaylist === image)   // still in Player mode
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

        #expect(coordinator.liveVisualPlaylist == nil)
        #expect(coordinator.visualKind == nil)
        #expect(coordinator.liveAudioPlaylist == nil)
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
        coordinator.togglePauseIfActive(image)
        #expect(image.playbackState == .paused)
        coordinator.togglePauseIfActive(image)
        #expect(image.playbackState == .playing)
    }

    @Test func togglePlaybackStartsStoppedAndTogglesLive() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(.image, folder: folder, files: [("1.jpg", []), ("2.jpg", [])], in: context)
        try context.save()
        let frames = image.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(image)
        image.currentFileID = frames[1].id
        coordinator.stop(image)
        #expect(image.playbackState == .stopped)

        // Stopped: the play/pause button starts it again, resuming from the remembered file —
        // a plain `togglePauseIfActive` would no-op because Stop removed the playlist from the channel.
        coordinator.playOrTogglePause(image)
        #expect(image.playbackState == .playing)
        #expect(image.currentFileID == frames[1].id)

        // Live: the same button now toggles pause/resume.
        coordinator.playOrTogglePause(image)
        #expect(image.playbackState == .paused)
        coordinator.playOrTogglePause(image)
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

        coordinator.playNow(image, startingAt: files[2])
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

        coordinator.playNow(image, startingAt: files[1])
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

    // MARK: - Audio overlay surface (Task 15)

    @Test func audioSurfaceReportsTheCurrentTrack() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["a1.mp3", "a2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("a1.mp3", []), ("a2.mp3", [])], in: context)
        try context.save()
        let tracks = audio.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        #expect(coordinator.audioCurrentFile?.id == tracks.first?.id)
        #expect(coordinator.audioDuration >= 0)
    }

    @Test func reconcileAudioJumpsWhenCurrentTrackFilteredOut() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3", "3.mp3"])
        let audio = makePlaylist(
            .audio, folder: folder,
            files: [("1.mp3", ["a"]), ("2.mp3", ["b"]), ("3.mp3", ["b"])], in: context
        )
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        let firstID = coordinator.audioCurrentFile?.id

        audio.filterState = FilterState(selectedTags: ["b"], filterMode: .or)
        coordinator.reconcile(playlistThatChanged: audio)

        let matching = audio.playbackSequence
        #expect(matching.map(\.fileName) == ["2.mp3", "3.mp3"])
        #expect(coordinator.audioCurrentFile?.id == matching.first?.id)
        #expect(coordinator.audioCurrentFile?.id != firstID)
    }

    @Test func reconcileAudioStopsTheChannelWhenSequenceEmpties() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", ["a"]), ("2.mp3", ["a"])], in: context)
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        #expect(coordinator.audioCurrentFile != nil)

        audio.filterState = FilterState(selectedTags: ["none"], filterMode: .or)
        coordinator.reconcile(playlistThatChanged: audio)

        // Unlike the visual channel (which stays live and empty so the player can show a "no files"
        // placeholder and the user can lift the filter from there), the audio channel has no such
        // placeholder, so an emptied audio sequence stops the playlist outright — easy to restart
        // from the same overlay.
        #expect(audio.playbackSequence.isEmpty)
        #expect(coordinator.liveAudioPlaylist == nil)           // the channel stops
        #expect(audio.playbackState == .stopped)
        #expect(coordinator.audioCurrentFile == nil)
    }

    @Test func playNowStartsAnIdleAudioChannel() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        try context.save()
        let tracks = audio.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        // Nothing is playing yet — the extended overlay opened on a restored playlist, or the
        // channel was stopped. Double-clicking a track must start it, not silently no-op.
        #expect(coordinator.liveAudioPlaylist == nil)
        coordinator.playNow(audio, startingAt: tracks[1])
        #expect(coordinator.liveAudioPlaylist === audio)
        #expect(coordinator.audioCurrentFile?.id == tracks[1].id)
    }

    @Test func switchingTrackFromPausedAudioChannelReturnsToPlaying() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3", "3.mp3"])
        let audio = makePlaylist(
            .audio, folder: folder,
            files: [("1.mp3", []), ("2.mp3", []), ("3.mp3", [])], in: context
        )
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        coordinator.togglePauseIfActive(audio)
        #expect(audio.playbackState == .paused)

        // Switching tracks from the compact overlay loads and auto-starts the new file, so the
        // transport must read Playing again rather than stay on the stale Pause/Play button.
        coordinator.next(audio)
        #expect(audio.playbackState == .playing)

        coordinator.togglePauseIfActive(audio)
        #expect(audio.playbackState == .paused)
        coordinator.previous(audio)
        #expect(audio.playbackState == .playing)
    }

    @Test func reconcileKeepsAPausedAudioChannelPaused() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3", "3.mp3"])
        let audio = makePlaylist(
            .audio, folder: folder,
            files: [("1.mp3", ["a"]), ("2.mp3", ["b"]), ("3.mp3", ["b"])], in: context
        )
        try context.save()

        // A recording engine reveals the re-suspend: mpv's real pause state isn't reflected
        // synchronously, so the test counts pause() calls instead.
        let recorder = try RecordingAudioEngine()
        let coordinator = PlaybackCoordinator(
            bookmarkService: BookmarkService(),
            makeVideoEngine: { recorder },
            makeAudioEngine: { recorder }
        )
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        coordinator.togglePauseIfActive(audio)                  // pause the channel (state .paused)
        #expect(audio.playbackState == .paused)
        let pausesBeforeReconcile = recorder.pauseCount

        // A filter drops the paused current track: reconcile jumps to the survivor, but the
        // channel must stay paused — loading the new file can't silently resume playback.
        audio.filterState = FilterState(selectedTags: ["b"], filterMode: .or)
        coordinator.reconcile(playlistThatChanged: audio)

        #expect(coordinator.audioCurrentFile?.fileName == "2.mp3")   // jumped to the survivor
        #expect(recorder.pauseCount > pausesBeforeReconcile)         // re-suspended, not resumed
    }

    /// An audio engine that counts `pause()` calls, so a test can tell a `jump` re-suspended a
    /// paused channel rather than resuming it.
    @MainActor
    private final class RecordingAudioEngine: MPVPlaybackEngine {
        private(set) var pauseCount = 0
        init() throws { try super.init(configuration: .audio) }
        override func pause() { pauseCount += 1; super.pause() }
    }

    @Test func advanceWhileSuppressedDoesNotFlipPausedToPlaying() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3", "3.mp3"])
        let audio = makePlaylist(
            .audio, folder: folder,
            files: [("1.mp3", []), ("2.mp3", []), ("3.mp3", [])], in: context
        )
        try context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        coordinator.pause(audio)            // its own pause → .paused
        coordinator.suppress()              // pause overlay up
        coordinator.next(audio)

        // An arrow key while the pause overlay is up must not resume a paused playlist: the
        // state stays Paused so lifting suppression doesn't silently treat it as playing.
        #expect(audio.playbackState == .paused)
        #expect(coordinator.isSuppressed)
    }

    @Test func advanceWhileSuppressedReSuspendsTheEngine() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3", "3.mp3"])
        let audio = makePlaylist(
            .audio, folder: folder,
            files: [("1.mp3", []), ("2.mp3", []), ("3.mp3", [])], in: context
        )
        try context.save()

        // A recording engine reveals the re-suspend: advancing loads (and auto-starts) the next
        // track, so the fix must immediately pause it back rather than let it play behind the overlay.
        let recorder = try RecordingAudioEngine()
        let coordinator = PlaybackCoordinator(
            bookmarkService: BookmarkService(),
            makeVideoEngine: { recorder },
            makeAudioEngine: { recorder }
        )
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        coordinator.suppress()
        let pausesBeforeAdvance = recorder.pauseCount

        coordinator.next(audio)
        #expect(audio.playbackState == .playing)            // it was playing; stays playing
        #expect(recorder.pauseCount > pausesBeforeAdvance)  // ...but re-suspended, not left audible
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

    // MARK: - File-position persistence (Task 16)

    /// An engine that records the resume position each `load` is asked to start at, so a test
    /// can assert whether file-position persistence threaded a saved position through.
    @MainActor
    private final class RecordingLoadEngine: MPVPlaybackEngine {
        private(set) var loadedPositions: [TimeInterval?] = []
        init() throws { try super.init(configuration: .audio) }
        override func load(_ file: PlaylistFile?, resource: String, startingAt position: TimeInterval?) {
            loadedPositions.append(position)
            super.load(file, resource: resource, startingAt: position)
        }
    }

    private func makeRecordingCoordinator(_ recorder: RecordingLoadEngine) -> PlaybackCoordinator {
        PlaybackCoordinator(
            bookmarkService: BookmarkService(),
            makeVideoEngine: { recorder },
            makeAudioEngine: { recorder }
        )
    }

    @Test func resumesFromSavedPositionWhenPersistenceOn() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        audio.preferences.filePositionPersistence = true
        try context.save()
        let tracks = audio.playbackSequence
        tracks[0].lastPosition = 30
        audio.currentFileID = tracks[0].id

        let recorder = try RecordingLoadEngine()
        let coordinator = makeRecordingCoordinator(recorder)
        defer { coordinator.shutdown() }

        coordinator.play(audio)   // resumes the remembered track, no explicit file
        #expect(recorder.loadedPositions.last == 30)
    }

    @Test func startsFromBeginningWhenPersistenceOff() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        // No per-playlist preference and the global default is off → no resume.
        try context.save()
        let tracks = audio.playbackSequence
        tracks[0].lastPosition = 30
        audio.currentFileID = tracks[0].id

        let recorder = try RecordingLoadEngine()
        let coordinator = makeRecordingCoordinator(recorder)
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        #expect(recorder.loadedPositions.last == .some(nil))
    }

    @Test func explicitFilePickResetsSavedPosition() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        audio.preferences.filePositionPersistence = true
        try context.save()
        let tracks = audio.playbackSequence
        tracks[1].lastPosition = 30

        let recorder = try RecordingLoadEngine()
        let coordinator = makeRecordingCoordinator(recorder)
        defer { coordinator.shutdown() }

        // A double-click / [enter] picks a file explicitly: it plays from the start and its
        // saved position is cleared, even with persistence on.
        coordinator.play(audio, startingAt: tracks[1])
        #expect(recorder.loadedPositions.last == .some(nil))
        #expect(tracks[1].lastPosition == nil)
    }

    @Test func writesPositionOnStopWhenEnabled() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        audio.preferences.filePositionPersistence = true
        try context.save()
        let tracks = audio.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)   // loads tracks[0]; its position starts unknown
        #expect(tracks[0].lastPosition == nil)
        coordinator.stop(audio)
        // Stopping captures the live position (0 for the non-decoding test file) — the point is
        // that the write happened, where an off playlist would leave it nil.
        #expect(tracks[0].lastPosition == 0)
    }

    @Test func doesNotWritePositionWhenDisabled() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        // Persistence off (no preference, default off).
        try context.save()
        let tracks = audio.playbackSequence
        tracks[0].lastPosition = 99   // a sentinel a write would overwrite

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)
        coordinator.stop(audio)
        #expect(tracks[0].lastPosition == 99)   // untouched: nothing was persisted
    }

    @Test func writesPositionBeforeJumpingAwayWhenEnabled() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp3", "2.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: [("1.mp3", []), ("2.mp3", [])], in: context)
        audio.preferences.filePositionPersistence = true
        try context.save()
        let tracks = audio.playbackSequence

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(audio)   // loads tracks[0]; its position starts unknown
        #expect(tracks[0].lastPosition == nil)
        coordinator.jump(audio, to: tracks[1])
        // Jumping captures the file we leave (0 for the non-decoding test file) before switching.
        #expect(tracks[0].lastPosition == 0)
    }
}
