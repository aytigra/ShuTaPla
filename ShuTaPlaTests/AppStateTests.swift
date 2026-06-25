//
//  AppStateTests.swift
//  ShuTaPlaTests
//
//  Task 4 — launch-mode determination and the folder → scan → playlist-creation
//  flow, driven through a mock file system so no real scanning is needed. A real
//  temp directory backs the bookmark (created via BookmarkService).
//

import Testing
import Foundation
import SwiftData
import AVFoundation
@testable import ShuTaPla

// MARK: - Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema([Playlist.self, PlaylistFile.self, AppStateModel.self, GlobalSettings.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShuTaPlaAppStateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func scanned(_ name: String, _ type: MediaType, tags: [String] = []) -> ScannedFile {
    ScannedFile(
        relativePath: name, fileName: name, mediaType: type,
        tags: tags, taggingStatus: tags.isEmpty ? .untagged : .valid, cloudStatus: .local
    )
}

/// Inserts a `PlaylistFile` into a playlist for the filtering/tagging tests.
@MainActor
@discardableResult
private func addFile(
    _ name: String,
    tags: [String] = [],
    status: TaggingStatus = .untagged,
    skipped: Bool = false,
    order: Int,
    to playlist: Playlist,
    in context: ModelContext
) -> PlaylistFile {
    let file = PlaylistFile(
        relativePath: name, fileName: name, tags: tags,
        taggingStatus: status, isSkipped: skipped, sortOrder: order
    )
    file.playlist = playlist
    context.insert(file)
    return file
}

/// Returns a canned scan result regardless of the bookmark it's handed, and a
/// canned update delta for re-scans.
private struct StubFileSystem: FileSystemProviding {
    let result: ScanResult
    var delta = UpdateDelta(added: [], removedRelativePaths: [])
    /// When set, `trashFiles` reports every URL as failed (a locked/permission-denied trash).
    var trashFails = false

    func scanFolder(bookmark: Data) async throws -> ScanResult { result }
    func updatePlaylist(bookmark: Data, knownRelativePaths: Set<String>) async throws -> UpdateDelta {
        delta
    }
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        url.deletingLastPathComponent().appendingPathComponent(newName)
    }
    func trashFiles(_ urls: [URL]) async throws -> TrashResult {
        trashFails ? TrashResult(trashed: [], failed: urls) : TrashResult(trashed: urls, failed: [])
    }
}

// MARK: - Tests

@MainActor
struct AppStateTests {

    @Test func launchWithEmptyDatabaseIsWelcomeMode() throws {
        let container = try makeContainer()
        let appState = AppState(modelContext: container.mainContext, fileSystem: StubFileSystem(result: emptyResult))
        #expect(appState.mode == .welcome)
    }

    @Test func launchWithExistingPlaylistIsManagerMode() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(Playlist(name: "Clips", folderBookmark: Data(), folderPath: "/tmp", mediaType: .video))
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        #expect(appState.mode == .manager)
    }

    // MARK: - Launch reconstruction & lifecycle (Task 16)

    /// A real temp folder holding the named (empty) files, with a bookmark, so a reconstructed
    /// channel's scoped access resolves at launch.
    @MainActor
    private func makeBookmarkedFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = try makeTempDir()
        for name in files { try Data().write(to: url.appending(path: name)) }
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    /// A relaunch with a Playing visual and a Playing audio playlist reopens Player mode and
    /// rebuilds both channels — Playing playlists resume. An image visual keeps the test off
    /// libmpv's video path; empty files fail to load without triggering an advance.
    @Test func launchResumesPlayingPlaylistsAndReopensPlayerMode() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeBookmarkedFolder(["i.jpg", "a.mp3"])
        defer { try? FileManager.default.removeItem(at: folder.url) }

        let image = Playlist(name: "Pics", folderBookmark: folder.bookmark,
                             folderPath: folder.url.path(percentEncoded: false), mediaType: .image)
        context.insert(image)
        let imageFile = addFile("i.jpg", order: 0, to: image, in: context)
        image.currentFileID = imageFile.id
        image.playbackState = .playing

        let audio = Playlist(name: "Tunes", folderBookmark: folder.bookmark,
                            folderPath: folder.url.path(percentEncoded: false), mediaType: .audio)
        context.insert(audio)
        addFile("a.mp3", order: 0, to: audio, in: context)
        audio.playbackState = .playing

        let model = AppStateModel.fetchOrCreate(in: context)
        model.audioChannelPlaylistId = audio.id
        try context.save()

        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        #expect(appState.mode == .player)
        #expect(appState.coordinator.liveVisualPlaylist === image)
        #expect(appState.coordinator.liveAudioPlaylist === audio)
    }

    /// A relaunch with everything Stopped stays in Manager and rebuilds no channel.
    @Test func launchWithAllStoppedStaysInManager() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(Playlist(name: "Clips", folderBookmark: Data(), folderPath: "/tmp", mediaType: .video))
        try context.save()

        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        #expect(appState.mode == .manager)
        #expect(appState.coordinator.liveVisualPlaylist == nil)
        #expect(appState.coordinator.liveAudioPlaylist == nil)
    }

    /// Closing the window suppresses both channels without changing their states; reopening lifts it.
    @Test func windowCloseSuppressesAndReopenLifts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeBookmarkedFolder(["a.mp3"])
        defer { try? FileManager.default.removeItem(at: folder.url) }

        let audio = Playlist(name: "Tunes", folderBookmark: folder.bookmark,
                            folderPath: folder.url.path(percentEncoded: false), mediaType: .audio)
        context.insert(audio)
        addFile("a.mp3", order: 0, to: audio, in: context)
        try context.save()

        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.coordinator.play(audio)
        #expect(audio.playbackState == .playing)

        appState.windowWasClosed()
        #expect(appState.coordinator.isSuppressed)
        #expect(audio.playbackState == .playing)   // suppression leaves the state alone

        appState.windowWillReopen()
        #expect(!appState.coordinator.isSuppressed)
        #expect(audio.playbackState == .playing)
    }

    /// The window frame round-trips through persisted state: nothing restored on first launch,
    /// then a persisted frame comes back unchanged (and survives a fresh `AppState` over the
    /// same store, as a relaunch would see it).
    @Test func windowFramePersistsAndRestores() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        #expect(appState.restoredWindowFrame == nil)   // first launch: no saved frame

        let frame = NSRect(x: 120, y: 240, width: 1280, height: 720)
        appState.persistWindowFrame(frame)
        #expect(appState.restoredWindowFrame == frame)

        let relaunched = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { relaunched.coordinator.shutdown() }
        #expect(relaunched.restoredWindowFrame == frame)
    }

    @Test func dominantFolderCreatesPlaylistAndSwitchesToManager() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b.mp4", .video, tags: ["beach"])],
            counts: [.video: 2],
            dominantType: .video
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await appState.addPlaylist(from: dir)

        guard case .created(let playlist) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(playlist.mediaType == .video)
        #expect(playlist.name == dir.lastPathComponent)
        #expect(playlist.files.count == 2)
        #expect(playlist.tagFrequency["beach"] == 1)
        #expect(appState.mode == .manager)
        #expect(appState.managedPlaylist === playlist)

        let persisted = try context.fetch(FetchDescriptor<Playlist>())
        #expect(persisted.count == 1)
    }

    @Test func mixedFolderPromptsThenCreatesWithChosenType() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("v0.mp4", .video), scanned("i0.jpg", .image), scanned("i1.jpg", .image)],
            counts: [.video: 1, .image: 2],
            dominantType: nil
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await appState.addPlaylist(from: dir)

        guard case .needsTypeChoice(let pending) = outcome else {
            Issue.record("expected .needsTypeChoice, got \(outcome)")
            return
        }
        #expect(appState.mode == .welcome)  // not created yet

        let playlist = appState.confirmPlaylist(pending, mediaType: .image)
        #expect(playlist.mediaType == .image)
        #expect(appState.mode == .manager)

        // The lone video file is kept but skipped; the two images are playable.
        let skipped = playlist.files.filter(\.isSkipped)
        #expect(skipped.count == 1)
        #expect(skipped.first?.fileName == "v0.mp4")
        #expect(playlist.files.filter { !$0.isSkipped }.count == 2)
    }

    @Test func emptyFolderReportsEmptyAndCreatesNothing() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await appState.addPlaylist(from: dir)

        guard case .empty = outcome else {
            Issue.record("expected .empty, got \(outcome)")
            return
        }
        #expect(appState.mode == .welcome)
        #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 0)
    }

    // MARK: - Shared add-playlist flow (drives observable AppState state)

    @Test func pendingTypeChoiceOrdersByFrequencyAndLabelsWithCounts() {
        let scan = ScanResult(files: [], counts: [.video: 1, .image: 3, .audio: 2], dominantType: nil)
        let pending = PendingPlaylist(name: "Mix", bookmark: Data(), folderPath: "/mix", scan: scan)

        #expect(pending.typeChoices == [.image, .audio, .video])   // most files first
        #expect(pending.choiceLabel(for: .image) == "Image (3)")
        #expect(pending.choiceLabel(for: .video) == "Video (1)")
    }

    @Test func importPlaylistFromMixedFolderRaisesTypeChoiceThenCreates() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("v0.mp4", .video), scanned("i0.jpg", .image), scanned("i1.jpg", .image)],
            counts: [.video: 1, .image: 2],
            dominantType: nil
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        await appState.importPlaylist(from: dir)

        #expect(appState.pendingTypeChoice != nil)   // Mixed folder raises the choice
        #expect(appState.isAddingPlaylist == false)  // spinner cleared on return
        #expect(appState.addPlaylistError == nil)
        #expect(appState.mode == .welcome)           // nothing created yet

        appState.confirmPendingTypeChoice(.image)

        #expect(appState.pendingTypeChoice == nil)   // dialog dismissed
        #expect(appState.mode == .manager)
        let persisted = try context.fetch(FetchDescriptor<Playlist>())
        #expect(persisted.count == 1)
        #expect(persisted.first?.mediaType == .image)
    }

    @Test func importPlaylistFromEmptyFolderSetsErrorAndCreatesNothing() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        await appState.importPlaylist(from: dir)

        #expect(appState.addPlaylistError != nil)
        #expect(appState.pendingTypeChoice == nil)
        #expect(appState.isAddingPlaylist == false)
        #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 0)
    }

    @Test func nonMatchingFilesAreMarkedSkipped() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b.mp4", .video), scanned("c.jpg", .image)],
            counts: [.video: 2, .image: 1],
            dominantType: .video
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        let skipped = playlist.files.filter(\.isSkipped)
        #expect(skipped.map(\.fileName) == ["c.jpg"])
    }

    // MARK: - Manager operations (Task 5)

    @Test func selectActivatesAndSetsSelection() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let video = Playlist(name: "Clips", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(video)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.manage(video)
        #expect(appState.managedPlaylist === video)
        #expect(appState.lastManagedVideoPlaylist === video)

        await appState.updateTask?.value  // let the background re-scan finish
    }

    @Test func renameUpdatesNameAndRejectsBlank() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let video = Playlist(name: "Old", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(video)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.rename(video, to: "  New  ")
        #expect(video.name == "New")

        appState.rename(video, to: "   ")
        #expect(video.name == "New")  // blank rejected
    }

    @Test func deleteRemovesPlaylistCompactsOrderAndClearsRefs() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .video, sortOrder: 0)
        let b = Playlist(name: "B", folderBookmark: Data(), folderPath: "/b", mediaType: .video, sortOrder: 1)
        let c = Playlist(name: "C", folderBookmark: Data(), folderPath: "/c", mediaType: .video, sortOrder: 2)
        [a, b, c].forEach(context.insert)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.manage(b)
        await appState.delete(b)  // cancels the in-flight update before b is freed
        await appState.updateTask?.value

        #expect(appState.managedPlaylist == nil)
        #expect(appState.lastManagedVideoPlaylist == nil)
        let remaining = try context.fetch(FetchDescriptor<Playlist>())
        #expect(remaining.count == 2)
        #expect(a.sortOrder == 0)
        #expect(c.sortOrder == 1)  // compacted from 2
    }

    @Test func reorderUpdatesSortOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .video, sortOrder: 0)
        let b = Playlist(name: "B", folderBookmark: Data(), folderPath: "/b", mediaType: .video, sortOrder: 1)
        let c = Playlist(name: "C", folderBookmark: Data(), folderPath: "/c", mediaType: .video, sortOrder: 2)
        [a, b, c].forEach(context.insert)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        // Move C to the front.
        appState.reorder([a, b, c], fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(c.sortOrder == 0)
        #expect(a.sortOrder == 1)
        #expect(b.sortOrder == 2)
    }

    @Test func updateAppliesDeltaAddingAndRemovingFiles() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b.mp4", .video)],
            counts: [.video: 2],
            dominantType: .video
        )
        let delta = UpdateDelta(added: [scanned("c.mp4", .video, tags: ["beach"])], removedRelativePaths: ["a.mp4"])
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result, delta: delta))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        #expect(playlist.files.count == 2)

        await appState.update(playlist)

        let names = Set(playlist.files.map(\.fileName))
        #expect(names == ["b.mp4", "c.mp4"])
        #expect(playlist.tagFrequency["beach"] == 1)
    }

    // MARK: - File operations (Task 6)

    @Test func reshufflePermutesPlayableAndKeepsSkippedLast() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        for i in 0..<5 {
            let file = PlaylistFile(relativePath: "v\(i).mp4", fileName: "v\(i).mp4", sortOrder: i)
            file.playlist = playlist
            context.insert(file)
        }
        let skipped = PlaylistFile(relativePath: "x.jpg", fileName: "x.jpg", isSkipped: true, sortOrder: 5)
        skipped.playlist = playlist
        context.insert(skipped)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.reshuffle(playlist)

        let playableOrders = Set(playlist.files.filter { !$0.isSkipped }.map(\.sortOrder))
        #expect(playableOrders == Set(0..<5))  // a permutation of the playable slots
        #expect(skipped.sortOrder == 5)         // skipped stays after the playable files
    }

    @Test func renameFileUpdatesNamePathAndTags() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let file = PlaylistFile(relativePath: "old.mp4", fileName: "old.mp4", sortOrder: 0)
        file.playlist = playlist
        context.insert(file)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.renameFile(file, to: "new [beach].mp4")

        #expect(error == nil)
        #expect(file.fileName == "new [beach].mp4")
        #expect(file.relativePath == "new [beach].mp4")
        #expect(file.tags == ["beach"])
        #expect(file.taggingStatus == .valid)
    }

    @Test func deleteFilesRemovesTrashedFromPlaylist() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = PlaylistFile(relativePath: "a.mp4", fileName: "a.mp4", sortOrder: 0)
        let b = PlaylistFile(relativePath: "b.mp4", fileName: "b.mp4", sortOrder: 1)
        a.playlist = playlist
        b.playlist = playlist
        context.insert(a)
        context.insert(b)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.deleteFiles([a])

        #expect(error == nil)
        #expect(Set(playlist.files.map(\.fileName)) == ["b.mp4"])
    }

    // MARK: - Strip audio (orchestration around AudioStripper)

    /// The first real codec-labeled sample whose filename starts with `prefix`,
    /// from `test_media/videos` two levels up from this test file (the repo root).
    private func videoSample(prefix: String) throws -> URL {
        let videos = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "test_media/videos", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil)
        return try #require(
            files.first { $0.lastPathComponent.hasPrefix(prefix) },
            "no sample with prefix \(prefix) in \(videos.path)"
        )
    }

    /// True when no leftover `.shutapla-strip-…` sidecar remains in `dir`.
    private func noStripSidecar(in dir: URL) throws -> Bool {
        let names = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        return !names.contains { $0.hasPrefix(".shutapla-strip-") }
    }

    @Test func stripAudioSwapsInAudioFreeFileBalancesSpinnerAndLeavesNoSidecar() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real h264 sample copied into the playlist folder; the file isn't on screen,
        // so the swap runs without touching the coordinator's visual channel.
        let source = dir.appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: try videoSample(prefix: "h264"), to: source)

        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let file = PlaylistFile(relativePath: "clip.mp4", fileName: "clip.mp4", sortOrder: 0)
        file.playlist = playlist
        context.insert(file)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.stripAudio(from: [file])

        #expect(error == nil)
        #expect(appState.strippingFileIDs.isEmpty)         // spinner inserted then removed
        #expect(try noStripSidecar(in: dir))               // hidden sibling cleaned up

        // The audio-free remux took the original's place at the same path.
        let asset = AVURLAsset(url: source)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(!video.isEmpty, "video track was dropped")
        #expect(audio.isEmpty, "audio track survived the swap")
    }

    @Test func stripAudioReportsFailureBalancesSpinnerAndLeavesNoSidecarWhenSourceMissing() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No file on disk: the early existence guard fails before AudioStripper runs.
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let file = PlaylistFile(relativePath: "missing.mp4", fileName: "missing.mp4", sortOrder: 0)
        file.playlist = playlist
        context.insert(file)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.stripAudio(from: [file])

        #expect(error == "Couldn't remove the audio.")
        #expect(appState.strippingFileIDs.isEmpty)         // balanced even on the failure path
        #expect(try noStripSidecar(in: dir))
    }

    // MARK: - Filtering (Task 7)

    @Test func tagFilterAppliesAndOrCorrectly() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", tags: ["beach", "sun"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b.mp4", tags: ["beach"], status: .valid, order: 1, to: playlist, in: context)
        addFile("c.mp4", order: 2, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.manage(playlist)

        appState.toggleFilterTag("beach", on: playlist)
        #expect(Set(appState.managerFiles.map(\.fileName)) == ["a.mp4", "b.mp4"])

        appState.toggleFilterTag("sun", on: playlist)  // AND beach + sun
        #expect(appState.managerFiles.map(\.fileName) == ["a.mp4"])

        appState.setFilterMode(.or, on: playlist)       // beach OR sun
        #expect(Set(appState.managerFiles.map(\.fileName)) == ["a.mp4", "b.mp4"])

        await appState.updateTask?.value
    }

    @Test func serviceFilterOverridesAndRestoresTagFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b.mp4", status: .untagged, order: 1, to: playlist, in: context)
        addFile("c.mp4", status: .invalid, order: 2, to: playlist, in: context)
        addFile("x.jpg", status: .untagged, skipped: true, order: 3, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.manage(playlist)

        appState.toggleFilterTag("beach", on: playlist)
        #expect(appState.managerFiles.map(\.fileName) == ["a.mp4"])

        appState.toggleServiceFilter(.untagged, on: playlist)  // overrides the tag filter
        #expect(appState.managerFiles.map(\.fileName) == ["b.mp4"])

        appState.toggleServiceFilter(.invalidTagging, on: playlist)  // mutually exclusive: replaces
        #expect(appState.managerFiles.map(\.fileName) == ["c.mp4"])

        appState.toggleServiceFilter(.skipped, on: playlist)
        #expect(appState.managerFiles.map(\.fileName) == ["x.jpg"])

        appState.toggleServiceFilter(.skipped, on: playlist)  // off → tag filter restored
        #expect(appState.managerFiles.map(\.fileName) == ["a.mp4"])

        await appState.updateTask?.value
    }

    @Test func switchingPlaylistsRestoresPersistedFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let p1 = Playlist(name: "P1", folderBookmark: Data(), folderPath: "/p1", mediaType: .video, sortOrder: 0)
        let p2 = Playlist(name: "P2", folderBookmark: Data(), folderPath: "/p2", mediaType: .video, sortOrder: 1)
        context.insert(p1)
        context.insert(p2)
        p1.filterState = FilterState(selectedTags: ["beach"], filterMode: .and)
        addFile("a.mp4", tags: ["beach"], status: .valid, order: 0, to: p1, in: context)
        addFile("b.mp4", order: 1, to: p1, in: context)
        addFile("c.mp4", order: 0, to: p2, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        // Each `manage` launches its own background re-scan; await each before the next so
        // no intermediate task is left running to touch a torn-down model after the body.
        appState.manage(p1)
        await appState.updateTask?.value
        #expect(appState.managerFiles.map(\.fileName) == ["a.mp4"])  // restored filter

        appState.manage(p2)
        await appState.updateTask?.value
        #expect(appState.managerFiles.map(\.fileName) == ["c.mp4"])  // no filter

        appState.manage(p1)
        await appState.updateTask?.value
        #expect(appState.managerFiles.map(\.fileName) == ["a.mp4"])  // restored again
    }

    // MARK: - Tag editing (Task 7)

    @Test func addTagRenamesFilesAndUpdatesFrequency() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = addFile("a.mp4", order: 0, to: playlist, in: context)
        let b = addFile("b.mp4", order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.addTag("beach", to: [a, b])

        #expect(error == nil)
        #expect(a.fileName == "a [beach].mp4")
        #expect(b.fileName == "b [beach].mp4")
        #expect(a.tags == ["beach"])
        #expect(playlist.tagFrequency["beach"] == 2)
    }

    @Test func batchTagEditSkipsInvalidFiles() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let good = addFile("a.mp4", order: 0, to: playlist, in: context)
        let bad = addFile("c [x][y].mp4", status: .invalid, order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.addTag("beach", to: [good, bad])

        #expect(error == nil)
        #expect(good.fileName == "a [beach].mp4")
        #expect(bad.fileName == "c [x][y].mp4")  // invalid file untouched
    }

    @Test func renameTagAcrossPlaylistRewritesEveryFile() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = addFile("a [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        let b = addFile("b [beach].mp4", tags: ["beach"], status: .valid, order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.renameTagAcrossPlaylist(playlist, from: "beach", to: "shore")

        #expect(error == nil)
        #expect(a.tags == ["shore"])
        #expect(b.tags == ["shore"])
        #expect(playlist.tagFrequency["shore"] == 2)
        #expect(playlist.tagFrequency["beach"] == nil)
    }

    @Test func renameTagAcrossPlaylistRewritesActiveFilterAndSavedSearches() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        addFile("a [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b [beach].mp4", tags: ["beach"], status: .valid, order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.manage(playlist)

        // Filter by "beach" and remember it as a saved search.
        appState.toggleFilterTag("beach", on: playlist)
        appState.saveCurrentSearch(on: playlist)
        #expect(appState.managerFiles.count == 2)

        let error = await appState.renameTagAcrossPlaylist(playlist, from: "beach", to: "shore")

        #expect(error == nil)
        // The active filter and the saved search follow the rename rather than pointing
        // at the now-nonexistent "beach", so the filtered list stays populated.
        #expect(playlist.filterState.selectedTags == ["shore"])
        #expect(playlist.savedSearches.first?.tags == ["shore"])
        #expect(appState.managerFiles.count == 2)

        await appState.updateTask?.value
    }

    @Test func removeTagAcrossPlaylistDropsItFromFilterAndSavedSearches() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        addFile("a [beach sun].mp4", tags: ["beach", "sun"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b [beach].mp4", tags: ["beach"], status: .valid, order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.manage(playlist)
        playlist.savedSearches = [
            SavedSearch(tags: ["beach"], mode: .or),
            SavedSearch(tags: ["beach", "sun"], mode: .or),
        ]

        appState.setFilterMode(.or, on: playlist)
        appState.toggleFilterTag("beach", on: playlist)
        appState.toggleFilterTag("sun", on: playlist)
        #expect(appState.managerFiles.count == 2)

        await appState.removeTagAcrossPlaylist(playlist, tag: "beach")

        // The removed tag is gone from the active filter; the beach-only saved search is
        // dropped (no tags left) and the combined one keeps only "sun".
        #expect(playlist.filterState.selectedTags == ["sun"])
        #expect(playlist.savedSearches.count == 1)
        #expect(playlist.savedSearches.first?.tags == ["sun"])
        #expect(playlist.savedSearches.first?.mode == .or)
        #expect(appState.managerFiles.count == 1)   // only the file that still has "sun"

        await appState.updateTask?.value
    }

    @Test func confirmPlayerDeleteSurfacesFailureAndKeepsFile() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let file = addFile("a.mp4", order: 0, to: playlist, in: context)
        var fileSystem = StubFileSystem(result: emptyResult)
        fileSystem.trashFails = true
        let appState = AppState(modelContext: context, fileSystem: fileSystem)

        appState.playerDeleteCandidate = file
        appState.confirmPlayerDelete()

        // The fire-and-forget trash fails, so the player reports the message instead of
        // silently advancing, and the file stays in the playlist.
        var waited = 0
        while appState.playerDeleteError == nil && waited < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(appState.playerDeleteError != nil)
        #expect(file.playlist === playlist)
        #expect(playlist.files.contains { $0 === file })
    }

    // MARK: - Saved searches (Task 7)

    @Test func savedSearchSavesRecallsAndMovesToTop() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", tags: ["beach", "sun"], status: .valid, order: 0, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.manage(playlist)

        appState.toggleFilterTag("beach", on: playlist)
        appState.saveCurrentSearch(on: playlist)
        appState.clearTagFilter(on: playlist)
        appState.toggleFilterTag("sun", on: playlist)
        appState.saveCurrentSearch(on: playlist)

        #expect(playlist.savedSearches.count == 2)
        #expect(playlist.savedSearches.first?.tags == ["sun"])

        // Re-applying the older one recalls it and moves it to the top (no dupe).
        appState.applySavedSearch(SavedSearch(tags: ["beach"], mode: .and), on: playlist)
        #expect(playlist.filterState.selectedTags == ["beach"])
        #expect(appState.managerFiles.map(\.fileName) == ["a.mp4"])
        #expect(playlist.savedSearches.count == 2)
        #expect(playlist.savedSearches.first?.tags == ["beach"])

        await appState.updateTask?.value
    }

    @Test func renameTagOntoExistingTagIsRefused() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = addFile("a [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b [shore].mp4", tags: ["shore"], status: .valid, order: 1, to: playlist, in: context)
        playlist.tagFrequency = ["beach": 1, "shore": 1]
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        // "shore" already exists as a distinct tag, so the rename is refused with a
        // message and no file is touched (rather than silently merging the two).
        let error = await appState.renameTagAcrossPlaylist(playlist, from: "beach", to: "shore")

        #expect(error != nil)
        #expect(a.fileName == "a [beach].mp4")
    }

    @Test func renameTagOntoTagHeldOnlyBySkippedFileIsRefused() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = addFile("a [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        // "shore" lives only on a skipped file, so it never enters `tagFrequency`; the
        // collision check must still see it and refuse the merge.
        addFile("x [shore].jpg", tags: ["shore"], status: .valid, skipped: true, order: 1, to: playlist, in: context)
        playlist.tagFrequency = ["beach": 1]
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.renameTagAcrossPlaylist(playlist, from: "beach", to: "shore")

        #expect(error != nil)
        #expect(a.fileName == "a [beach].mp4")   // untouched
    }

    @Test func reselectingTheSamePlaylistReScansTheFolder() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", order: 0, to: playlist, in: context)
        // Each (re-)scan rediscovers the same extra file, so a re-read shows as another append.
        let delta = UpdateDelta(added: [scanned("new.mp4", .video)], removedRelativePaths: [])
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, delta: delta))

        appState.manage(playlist)
        let firstScan = appState.updateTask
        await appState.updateTask?.value
        #expect(playlist.files.count == 2)        // a.mp4 + the discovered new.mp4

        // Re-clicking the already-selected row re-reads the folder — the automatic Update, the
        // reason there's no dedicated control — so it spawns a fresh scan rather than no-op'ing.
        appState.manage(playlist)
        #expect(appState.updateTask != firstScan)
        await appState.updateTask?.value
        #expect(playlist.files.count == 3)
    }

    @Test func selectingADifferentPlaylistDoesNotCancelTheFirstScan() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .video)
        let b = Playlist(name: "B", folderBookmark: Data(), folderPath: "/b", mediaType: .video)
        context.insert(a)
        context.insert(b)
        addFile("a.mp4", order: 0, to: a, in: context)
        addFile("b.mp4", order: 0, to: b, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        // Selecting A starts A's background re-scan; selecting a *different* playlist B must not
        // cancel A's scan — the two playlists' re-reads are independent (keyed per playlist).
        appState.manage(a)
        let scanA = appState.updateTask
        appState.manage(b)
        #expect(scanA?.isCancelled == false)

        await scanA?.value
        await appState.updateTask?.value
    }

    @Test func horizontalArrowInListIsConsumedWithoutChangingSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", order: 0, to: playlist, in: context)
        addFile("b.mp4", order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = playlist

        // List view (one column), nothing selected: a left/right key has no axis to
        // move along, so it is swallowed (no beep) without selecting a file.
        let consumed = appState.moveFileSelection(.left)

        #expect(consumed)
        #expect(appState.managerSelection.isEmpty)
    }

    @Test func moveFileSelectionClampsAtGridEdgesWithoutLosingSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let names = (1...6).map { "\($0).jpg" }
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        playlist.preferences.viewMode = .gallery
        for (i, name) in names.enumerated() { addFile(name, order: i, to: playlist, in: context) }
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = playlist
        appState.fileGridColumns = 3
        let files = appState.managerFiles

        // Top-left cell selected: moving up (−3 → row −1) and left (−1 → off the row start)
        // both fall off the grid. The key is still consumed (no beep) but the selection
        // is held in place rather than cleared or wrapped.
        appState.managerSelection = [files[0].id]
        #expect(appState.moveFileSelection(.up))
        #expect(appState.managerSelection == [files[0].id])
        #expect(appState.moveFileSelection(.left))
        #expect(appState.managerSelection == [files[0].id])

        // Bottom-right cell: moving down (+3) and right (+1) both run past the last index.
        appState.managerSelection = [files[5].id]
        #expect(appState.moveFileSelection(.down))
        #expect(appState.managerSelection == [files[5].id])
        #expect(appState.moveFileSelection(.right))
        #expect(appState.managerSelection == [files[5].id])
    }

    @Test func saveCurrentSearchIsANoOpWithAnEmptyFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = playlist

        // No tags selected → nothing to remember.
        appState.saveCurrentSearch(on: playlist)
        #expect(playlist.savedSearches.isEmpty)
    }

    @Test func saveCurrentSearchCapsRecentsAtTen() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = playlist

        // Remember twelve distinct searches; only the ten most recent survive, newest first.
        for i in 0..<12 {
            appState.clearTagFilter(on: playlist)
            appState.toggleFilterTag("t\(i)", on: playlist)
            appState.saveCurrentSearch(on: playlist)
        }

        #expect(playlist.savedSearches.count == 10)
        #expect(playlist.savedSearches.first?.tags == ["t11"])
        #expect(playlist.savedSearches.last?.tags == ["t2"])   // t0/t1 dropped off the end
    }

    @Test func rescanRemovalClearsPendingDeleteForThatFile() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = addFile("a.mp4", order: 0, to: playlist, in: context)
        let stub = StubFileSystem(
            result: emptyResult,
            delta: UpdateDelta(added: [], removedRelativePaths: ["a.mp4"])
        )
        let appState = AppState(modelContext: context, fileSystem: stub)
        appState.managedPlaylist = playlist
        appState.pendingManagerDelete = [a]

        // The re-scan prunes "a.mp4"; the pending delete that targeted it must be
        // cleared so confirming can't dereference the destroyed model.
        await appState.update(playlist)

        #expect(appState.pendingManagerDelete.isEmpty)
    }

    // MARK: - Audio overlay (Task 15)

    @Test func audioFilterTogglesAndRecomputesIndependently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        addFile("1.mp3", tags: ["jazz", "mellow"], status: .valid, order: 0, to: audio, in: context)
        addFile("2.mp3", tags: ["jazz"], status: .valid, order: 1, to: audio, in: context)
        addFile("3.mp3", order: 2, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.rememberLastManaged(audio)   // occupy the audio channel slot; channel files derive from it
        #expect(appState.audioChannelFiles.count == 3)

        appState.toggleFilterTag("jazz", on: audio)
        #expect(Set(appState.audioChannelFiles.map(\.fileName)) == ["1.mp3", "2.mp3"])

        appState.toggleFilterTag("mellow", on: audio)       // AND jazz + mellow
        #expect(appState.audioChannelFiles.map(\.fileName) == ["1.mp3"])

        appState.setFilterMode(.or, on: audio)              // jazz OR mellow
        #expect(Set(appState.audioChannelFiles.map(\.fileName)) == ["1.mp3", "2.mp3"])

        appState.clearTagFilter(on: audio)
        #expect(appState.audioChannelFiles.count == 3)
    }

    @Test func startPlaybackOfAudioLeavesManagerSelectionUntouched() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let video = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(video)
        context.insert(audio)
        addFile("v.mp4", order: 0, to: video, in: context)
        addFile("a.mp3", order: 0, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.manage(video)
        #expect(appState.managedPlaylist === video)

        // Audio plays on its own independent channel: the Manager keeps showing the
        // video playlist and the window does not enter Player mode.
        appState.startPlayback(of: audio)
        #expect(appState.managedPlaylist === video)
        #expect(appState.audioChannelPlaylist === audio)
        #expect(appState.mode == .manager)

        await appState.updateTask?.value
    }

    @Test func deletingThePlayingAudioPlaylistStopsTheCoordinator() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "a.mp3"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "A", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        addFile("a.mp3", order: 0, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: audio)
        #expect(appState.coordinator.liveAudioPlaylist === audio)

        // Deleting the playlist must release the audio channel, or the engine keeps playing
        // (and the next advance dereferences) files that no longer exist.
        await appState.delete(audio)
        #expect(appState.coordinator.liveAudioPlaylist == nil)
    }

    @Test func confirmAudioDeleteAdvancesPastTheTrashedTrack() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "1.mp3"))
        try Data().write(to: dir.appending(path: "2.mp3"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "A", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        let first = addFile("1.mp3", order: 0, to: audio, in: context)
        let second = addFile("2.mp3", order: 1, to: audio, in: context)
        let secondID = second.id
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: audio)
        #expect(audio.currentFileID == first.id)

        // Trashing the playing track must advance the channel to the survivor, mirroring the
        // visual confirmPlayerDelete; otherwise the engine stays on the deleted file.
        appState.audioDeleteCandidate = first
        appState.confirmAudioDelete()

        var waited = 0
        while audio.files.count > 1 && waited < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(audio.files.count == 1)
        #expect(audio.currentFileID == secondID)   // reconciled past the trashed track
    }

    @Test func confirmManagerDeleteAdvancesTheLiveAudioChannel() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "1.mp3"))
        try Data().write(to: dir.appending(path: "2.mp3"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "A", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        let first = addFile("1.mp3", order: 0, to: audio, in: context)
        let second = addFile("2.mp3", order: 1, to: audio, in: context)
        let secondID = second.id
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: audio)
        #expect(audio.currentFileID == first.id)

        // Deleting the playing track from the Manager file list must advance the live audio
        // channel off it, exactly as the audio-overlay delete does — otherwise the engine keeps
        // the destroyed model and its next advance dereferences it.
        appState.requestManagerDelete([first])
        appState.confirmManagerDelete()

        var waited = 0
        while audio.files.count > 1 && waited < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(audio.files.count == 1)
        #expect(audio.currentFileID == secondID)   // reconciled past the trashed track
    }

    @Test func rescanPruneAdvancesTheLiveVisualChannel() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "1.jpg"))
        try Data().write(to: dir.appending(path: "2.jpg"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let image = Playlist(name: "I", folderBookmark: bookmark, folderPath: dir.path, mediaType: .image)
        context.insert(image)
        let first = addFile("1.jpg", order: 0, to: image, in: context)
        let second = addFile("2.jpg", order: 1, to: image, in: context)
        let secondID = second.id
        // The re-scan reports the on-screen file gone from disk.
        let delta = UpdateDelta(added: [], removedRelativePaths: ["1.jpg"])
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, delta: delta))
        defer { appState.coordinator.shutdown() }

        // Play the image playlist on the visual channel (the image engine has no libmpv, so this
        // is trap-safe).
        appState.coordinator.play(image)
        #expect(image.currentFileID == first.id)

        // The background Update prunes the playing file; apply() must advance the visual channel
        // off it — the symmetric counterpart to the audio reconcile — not leave the engine on a
        // destroyed model.
        await appState.update(image)

        #expect(image.files.map(\.fileName) == ["2.jpg"])
        #expect(image.currentFileID == secondID)
    }

    @Test func playOnAudioChannelStartsPlaybackAndReScansEachClick() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "a.mp3"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "A", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        addFile("a.mp3", order: 0, to: audio, in: context)
        let delta = UpdateDelta(added: [scanned("new.mp3", .audio)], removedRelativePaths: [])
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, delta: delta))
        defer { appState.coordinator.shutdown() }

        let tokenBefore = appState.audioScrollToken
        appState.playOnAudioChannel(audio)
        #expect(appState.audioChannelPlaylist === audio)
        #expect(appState.coordinator.liveAudioPlaylist === audio)   // a new selection starts playing
        #expect(appState.audioScrollToken > tokenBefore)        // asks the file list to re-center
        await appState.updateTask?.value
        #expect(audio.files.count == 2)                         // re-read the folder

        // Re-selecting the active audio playlist re-reads the folder again (no dedicated control)
        // and re-centers the list once more.
        let tokenAfterFirst = appState.audioScrollToken
        appState.playOnAudioChannel(audio)
        #expect(appState.audioScrollToken > tokenAfterFirst)
        await appState.updateTask?.value
        #expect(audio.files.count == 3)
    }

    @Test func addingAudioPlaylistInPlayerModePlaysNewAndStopsOld() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dirA = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirA) }
        try Data().write(to: dirA.appending(path: "a.mp3"))
        let bookmarkA = try BookmarkService.makeBookmark(for: dirA)
        let a = Playlist(name: "A", folderBookmark: bookmarkA, folderPath: dirA.path, mediaType: .audio)
        context.insert(a)
        addFile("a.mp3", order: 0, to: a, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: a)
        #expect(appState.coordinator.liveAudioPlaylist === a)

        // Creating a playlist from the player-mode audio overlay (mode == .player) starts it
        // playing — and switching the audio channel stops the one that was live.
        appState.mode = .player
        appState.switchScope(to: .image)   // browsing images; the player-mode create must not switch it
        let dirB = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirB) }
        try Data().write(to: dirB.appending(path: "b.mp3"))
        let bookmarkB = try BookmarkService.makeBookmark(for: dirB)
        let scan = ScanResult(files: [scanned("b.mp3", .audio)], counts: [.audio: 1], dominantType: .audio)
        let b = appState.makePlaylist(name: "B", bookmark: bookmarkB, folderPath: dirB.path, scan: scan, mediaType: .audio)

        #expect(appState.audioChannelPlaylist === b)
        #expect(appState.coordinator.liveAudioPlaylist === b)   // the new playlist is what's playing
        #expect(a.playbackState == .stopped)                // the previous one stopped
        #expect(appState.managerScope == .image)            // scope unchanged by a player-mode create
    }

    @Test func addingAudioPlaylistInManagerModeSelectsStoppedAndStopsOld() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dirA = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirA) }
        try Data().write(to: dirA.appending(path: "a.mp3"))
        let bookmarkA = try BookmarkService.makeBookmark(for: dirA)
        let a = Playlist(name: "A", folderBookmark: bookmarkA, folderPath: dirA.path, mediaType: .audio)
        context.insert(a)
        addFile("a.mp3", order: 0, to: a, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: a)
        #expect(appState.coordinator.liveAudioPlaylist === a)

        // Creating an audio playlist in Manager selects it stopped, releasing the audio playlist
        // that was playing so it doesn't keep going behind the new selection.
        appState.mode = .manager
        let dirB = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirB) }
        try Data().write(to: dirB.appending(path: "b.mp3"))
        let bookmarkB = try BookmarkService.makeBookmark(for: dirB)
        let scan = ScanResult(files: [scanned("b.mp3", .audio)], counts: [.audio: 1], dominantType: .audio)
        let b = appState.makePlaylist(name: "B", bookmark: bookmarkB, folderPath: dirB.path, scan: scan, mediaType: .audio)

        #expect(appState.audioChannelPlaylist === b)
        #expect(appState.managedPlaylist === b)              // managed in Manager-mode create
        #expect(appState.coordinator.liveAudioPlaylist == nil)   // nothing left playing
        #expect(a.playbackState == .stopped)
        #expect(appState.managerScope == .audio)             // Manager-mode create switches scope
    }

    @Test func playOnVisualChannelPlaysNewAndReCentersEachClick() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir1 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir1) }
        try Data().write(to: dir1.appending(path: "1.png"))
        let b1 = try BookmarkService.makeBookmark(for: dir1)
        let p1 = Playlist(name: "P1", folderBookmark: b1, folderPath: dir1.path, mediaType: .image)
        context.insert(p1)
        addFile("1.png", order: 0, to: p1, in: context)
        let dir2 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        try Data().write(to: dir2.appending(path: "2.png"))
        let b2 = try BookmarkService.makeBookmark(for: dir2)
        let p2 = Playlist(name: "P2", folderBookmark: b2, folderPath: dir2.path, mediaType: .image)
        context.insert(p2)
        addFile("2.png", order: 0, to: p2, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: p1)
        #expect(appState.coordinator.liveVisualPlaylist === p1)

        // Switching to a different playlist in the overlay starts it playing and re-centers.
        let token0 = appState.scrollSelectionToken
        appState.playOnVisualChannel(p2)
        #expect(appState.coordinator.liveVisualPlaylist === p2)   // a new selection plays
        #expect(appState.scrollSelectionToken > token0)        // asks the file list to re-center
        await appState.updateTask?.value

        // Re-clicking the already-playing playlist re-centers again without restarting it.
        let token1 = appState.scrollSelectionToken
        appState.playOnVisualChannel(p2)
        #expect(appState.coordinator.liveVisualPlaylist === p2)
        #expect(appState.scrollSelectionToken > token1)
        await appState.updateTask?.value
    }

    @Test func audioRescanAdvancesOffARemovedPlayingTrack() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "1.mp3"))
        try Data().write(to: dir.appending(path: "2.mp3"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "A", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        let first = addFile("1.mp3", order: 0, to: audio, in: context)
        let second = addFile("2.mp3", order: 1, to: audio, in: context)
        let secondID = second.id
        // The re-scan prunes the track that's currently playing.
        let delta = UpdateDelta(added: [], removedRelativePaths: ["1.mp3"])
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, delta: delta))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: audio)
        #expect(audio.currentFileID == first.id)

        await appState.update(audio)            // a re-scan that removes the playing track
        #expect(audio.files.count == 1)
        #expect(audio.currentFileID == secondID)   // reconciled off the pruned track
    }

    @Test func audioRescanRemovalClearsPendingAudioDelete() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        let doomed = addFile("1.mp3", order: 0, to: audio, in: context)
        addFile("2.mp3", order: 1, to: audio, in: context)
        let delta = UpdateDelta(added: [], removedRelativePaths: ["1.mp3"])
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, delta: delta))

        // A trash confirmation pointing at a file the re-scan prunes must not survive to act
        // on a destroyed model.
        appState.audioDeleteCandidate = doomed
        await appState.update(audio)
        #expect(appState.audioDeleteCandidate == nil)
    }

    @Test func currentAudioFileResolvesFromTheModelWhenStopped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        addFile("1.mp3", order: 0, to: audio, in: context)
        let second = addFile("2.mp3", order: 1, to: audio, in: context)
        audio.currentFileID = second.id
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.rememberLastManaged(audio)   // loads the audio channel slot without playing

        // Nothing is playing, so the engine holds no live track — yet the overlay still resolves
        // the current file from the playlist's persisted resume position, exactly as the Manager
        // does. A stopped audio playlist shows (and resumes from) where it left off.
        #expect(appState.coordinator.audioCurrentFile == nil)
        #expect(appState.currentAudioFile?.id == second.id)
    }

    @Test func currentAudioFileIsNilWhenTheResumeTrackIsFilteredOut() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        let tagged = addFile("1.mp3", tags: ["jazz"], status: .valid, order: 0, to: audio, in: context)
        addFile("2.mp3", order: 1, to: audio, in: context)
        audio.currentFileID = tagged.id
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.rememberLastManaged(audio)
        appState.toggleFilterTag("blues", on: audio)   // a filter the resume track does not match

        // Mirrors the Manager: when the remembered file is filtered out of view, there's
        // nothing to highlight or center on.
        #expect(appState.currentAudioFile == nil)
    }

    @Test func audioOverlayHidesSkippedTracksAndNeverMakesOneCurrent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        addFile("1.mp3", order: 0, to: audio, in: context)
        let skipped = addFile("2.mp3", skipped: true, order: 1, to: audio, in: context)
        // The Skipped triage filter is the one effective filter whose display list contains skipped
        // files; honoring it in the overlay would otherwise surface them on the audio channel.
        audio.filterState = FilterState(selectedTags: [], filterMode: .and, serviceFilter: .skipped)
        audio.currentFileID = skipped.id
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.rememberLastManaged(audio)

        // The audio overlay is a transport list, not a triage surface: skipped tracks are never
        // playable, so they must not appear in it, and a skipped resume track must not resolve as
        // the current (transport) track. Under the Skipped filter nothing is playable, so the list
        // is empty.
        #expect(appState.audioChannelFiles.allSatisfy { !$0.isSkipped })
        #expect(appState.audioChannelFiles.isEmpty)
        #expect(appState.currentAudioFile == nil)
    }

    @Test func currentVisualFileResolvesFromTheLiveVisualPlaylist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "1.jpg"))
        try Data().write(to: dir.appending(path: "2.jpg"))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let image = Playlist(name: "I", folderBookmark: bookmark, folderPath: dir.path, mediaType: .image)
        context.insert(image)
        let first = addFile("1.jpg", order: 0, to: image, in: context)
        addFile("2.jpg", order: 1, to: image, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.coordinator.play(image)   // the image engine has no libmpv, so this is trap-safe

        // The Files & Tags overlay resolves its highlighted/centered file from the live visual
        // playlist's persisted current id against the displayed list.
        #expect(appState.currentVisualFile?.id == first.id)
        #expect(appState.currentVisualFile?.id == appState.visualChannelFiles.first?.id)
    }

    // MARK: - Manager audio scope (audio manager redesign — Phase 2)
    //
    // Stop-on-switch and the inlet Play cascade. These exercise the live audio channel, so
    // each backs its playlist with a real temp folder holding an empty placeholder file: the
    // window-free `AudioPlaybackEngine` (`vo=null`) plays it, the empty file fails to load
    // (so no natural-EOF advance touches a model after teardown), and `shutdown()` is deferred.

    /// Builds an audio playlist backed by a real temp folder with one empty placeholder file,
    /// so `coordinator.play` can engage the engine. Returns the folder so the caller can
    /// remove it; the caller owns (and holds) the `ModelContainer` behind `context`.
    @MainActor
    private func makeLiveAudioPlaylist(_ name: String, file: String, in context: ModelContext) throws -> (Playlist, URL) {
        let dir = try makeTempDir()
        try Data().write(to: dir.appending(path: file))
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: name, folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(playlist)
        addFile(file, order: 0, to: playlist, in: context)
        return (playlist, dir)
    }

    @Test func managerAudioSelectStopsThePreviouslyPlayingPlaylist() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (a, dirA) = try makeLiveAudioPlaylist("A", file: "a.mp3", in: context)
        let (b, dirB) = try makeLiveAudioPlaylist("B", file: "b.mp3", in: context)
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: a)
        #expect(appState.coordinator.liveAudioPlaylist === a)

        // Switching to a different audio playlist in Manager stops the live one and leaves the
        // new one managed but stopped — only ever one audio playlist live.
        appState.manage(b)
        #expect(a.playbackState == .stopped)
        #expect(appState.audioChannelPlaylist === b)
        #expect(b.playbackState == .stopped)
        #expect(appState.coordinator.liveAudioPlaylist == nil)

        await appState.updateTask?.value
    }

    @Test func reselectingTheActiveAudioPlaylistKeepsItPlaying() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (a, dir) = try makeLiveAudioPlaylist("A", file: "a.mp3", in: context)
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: a)
        #expect(appState.coordinator.liveAudioPlaylist === a)

        // Re-selecting the already-live playlist re-scans and re-centers without stopping it.
        appState.manage(a)
        #expect(appState.coordinator.liveAudioPlaylist === a)
        #expect(a.playbackState == .playing)

        await appState.updateTask?.value
    }

    @Test func inletPlayWithNoAudioPlaylistsRaisesTheAddFlow() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startFirstAudioPlaylistOrAdd()
        #expect(appState.isImportingPlaylist)
        #expect(appState.audioChannelPlaylist == nil)
    }

    @Test func inletPlayStartsTheFirstAudioPlaylistWhenSomeExist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (audio, dir) = try makeLiveAudioPlaylist("A", file: "a.mp3", in: context)
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.startFirstAudioPlaylistOrAdd()
        #expect(appState.audioChannelPlaylist === audio)
        #expect(appState.coordinator.liveAudioPlaylist === audio)
        #expect(!appState.isImportingPlaylist)
    }

    // MARK: - New Playlist switches scope (audio manager redesign — Phase 3)
    //
    // The toolbar's New Playlist runs through the same `addPlaylist` creation chokepoint as
    // every other add path, so creating a playlist switches the Manager to the created type's
    // scope and makes it that scope's selection. No engine: a visual create stays off libmpv,
    // and an audio create activates the playlist without starting it.

    @Test func creatingVisualPlaylistSwitchesToVideoScopeAndManagesIt() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video)], counts: [.video: 1], dominantType: .video
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        defer { appState.coordinator.shutdown() }
        appState.switchScope(to: .audio)   // start in another scope to prove the switch
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await appState.addPlaylist(from: dir)
        guard case .created(let playlist) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(appState.managerScope == .video)
        #expect(appState.managedPlaylist === playlist)
    }

    @Test func creatingAudioPlaylistSwitchesToAudioScopeWithoutPlaying() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp3", .audio)], counts: [.audio: 1], dominantType: .audio
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        defer { appState.coordinator.shutdown() }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await appState.addPlaylist(from: dir)
        guard case .created(let playlist) = outcome else {
            Issue.record("expected .created, got \(outcome)")
            return
        }
        #expect(appState.managerScope == .audio)
        #expect(appState.managedPlaylist === playlist)
        #expect(appState.audioChannelPlaylist === playlist)
        #expect(appState.coordinator.liveAudioPlaylist == nil)   // created, never started
        #expect(appState.lastManagedVideoPlaylist == nil)     // visual memory untouched
    }

    // MARK: - Slot model & scope switching

    /// A Manager fixture with one playlist of each type, each holding two files. Holds the
    /// `ModelContainer` so the test body keeps it alive (an orphaned context traps on fetch).
    private struct SlotEnv {
        let container: ModelContainer
        let appState: AppState
        let video: Playlist
        let image: Playlist
        let audio: Playlist
    }

    @MainActor
    private func makeSlotState() throws -> SlotEnv {
        let container = try makeContainer()
        let context = container.mainContext
        let video = Playlist(name: "Clips", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        let image = Playlist(name: "Pics", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        let audio = Playlist(name: "Tunes", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        [video, image, audio].forEach(context.insert)
        addFile("v1.mp4", order: 0, to: video, in: context)
        addFile("v2.mp4", order: 1, to: video, in: context)
        addFile("p1.jpg", order: 0, to: image, in: context)
        addFile("p2.jpg", order: 1, to: image, in: context)
        addFile("a1.mp3", order: 0, to: audio, in: context)
        addFile("a2.mp3", order: 1, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        return SlotEnv(container: container, appState: appState, video: video, image: image, audio: audio)
    }

    @Test func managedFilesDeriveFromTheManagedPlaylist() throws {
        let env = try makeSlotState()
        let appState = env.appState

        appState.managedPlaylist = env.image
        #expect(appState.managerFiles.map(\.fileName) == ["p1.jpg", "p2.jpg"])

        appState.managedPlaylist = env.video
        #expect(appState.managerFiles.map(\.fileName) == ["v1.mp4", "v2.mp4"])
    }

    @Test func switchScopeLoadsThatScopesRememberedPlaylist() async throws {
        let env = try makeSlotState()
        let appState = env.appState

        // Manage a video, then browse to the image scope: the managed slot becomes the
        // remembered image playlist (here none), while the video stays remembered.
        // Each `manage` launches a background re-scan; await it before moving on so no task is
        // left to touch a torn-down model after the body.
        appState.manage(env.video)
        await appState.updateTask?.value
        #expect(appState.managerScope == .video)
        #expect(appState.managedPlaylist === env.video)

        appState.switchScope(to: .image)
        #expect(appState.managerScope == .image)
        #expect(appState.managedPlaylist == nil)   // no image remembered yet → placeholder

        // Picking an image makes it managed and remembered, independently of the video.
        appState.manage(env.image)
        await appState.updateTask?.value
        #expect(appState.managedPlaylist === env.image)

        // Returning to the video scope restores the remembered video.
        appState.switchScope(to: .video)
        #expect(appState.managedPlaylist === env.video)
    }

    @Test func switchingToAudioScopeLoadsTheAudioChannelSlot() async throws {
        let env = try makeSlotState()
        let appState = env.appState
        appState.manage(env.video)
        await appState.updateTask?.value   // drain the re-scan before the body returns
        appState.rememberLastManaged(env.audio)   // an audio playlist sitting in the channel

        appState.switchScope(to: .audio)
        #expect(appState.managedPlaylist === env.audio)   // synced from the audio channel slot
    }

    @Test func rememberKeepsVisualMemoriesIndependent() throws {
        let env = try makeSlotState()
        let appState = env.appState

        // Recording a video then an image leaves both remembered — the visual memories don't
        // overwrite each other (only the *playing* visual channel is mutually exclusive).
        appState.rememberLastManaged(env.video)
        appState.rememberLastManaged(env.image)
        #expect(appState.lastManagedVideoPlaylist === env.video)
        #expect(appState.lastManagedImagePlaylist === env.image)
        #expect(appState.appStateModel.lastManagedVideoPlaylistId == env.video.id)
        #expect(appState.appStateModel.lastManagedImagePlaylistId == env.image.id)
    }

    // MARK: - Filtering edits the managed playlist

    @Test func deletingAManagedFileClearsItFromTheSelection() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "Tunes", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        let t1 = addFile("t1.mp3", order: 0, to: audio, in: context)
        let t2 = addFile("t2.mp3", order: 1, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = audio
        appState.managerSelection = [t1.id, t2.id]

        let error = await appState.deleteFiles([t1])

        #expect(error == nil)
        #expect(Set(audio.files.map(\.fileName)) == ["t2.mp3"])
        #expect(appState.managerSelection == [t2.id])   // the trashed track drops out
    }

    @Test func taggingFilesEditsThePlaylist() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let audio = Playlist(name: "Tunes", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        context.insert(audio)
        let t1 = addFile("t1.mp3", order: 0, to: audio, in: context)
        let t2 = addFile("t2.mp3", order: 1, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let error = await appState.addTag("jazz", to: [t1, t2])

        #expect(error == nil)
        #expect(t1.tags == ["jazz"])
        #expect(t2.tags == ["jazz"])
        #expect(audio.tagFrequency["jazz"] == 2)
    }

    private var emptyResult: ScanResult {
        ScanResult(files: [], counts: [:], dominantType: nil)
    }
}
