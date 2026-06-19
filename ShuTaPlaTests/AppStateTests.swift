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
        #expect(appState.activeVideoPlaylist === playlist)

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

    @Test func activateEnforcesVisualChannelExclusivity() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let video = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        let image = Playlist(name: "I", folderBookmark: Data(), folderPath: "/i", mediaType: .image)
        context.insert(video)
        context.insert(image)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.activate(video)
        #expect(appState.activeVideoPlaylist === video)
        #expect(appState.activeImagePlaylist == nil)

        appState.activate(image)
        #expect(appState.activeImagePlaylist === image)
        #expect(appState.activeVideoPlaylist == nil)
        #expect(appState.appStateModel.activeVideoPlaylistId == nil)
        #expect(appState.appStateModel.activeImagePlaylistId == image.id)
    }

    // MARK: - Manager operations (Task 5)

    @Test func selectActivatesAndSetsSelection() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let video = Playlist(name: "Clips", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(video)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.select(video)
        #expect(appState.selectedPlaylist === video)
        #expect(appState.activeVideoPlaylist === video)

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

        appState.select(b)
        await appState.delete(b)  // cancels the in-flight update before b is freed
        await appState.updateTask?.value

        #expect(appState.selectedPlaylist == nil)
        #expect(appState.activeVideoPlaylist == nil)
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
        appState.select(playlist)

        appState.toggleFilterTag("beach")
        #expect(Set(appState.filteredFiles.map(\.fileName)) == ["a.mp4", "b.mp4"])

        appState.toggleFilterTag("sun")  // AND beach + sun
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])

        appState.setFilterMode(.or)       // beach OR sun
        #expect(Set(appState.filteredFiles.map(\.fileName)) == ["a.mp4", "b.mp4"])

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
        appState.select(playlist)

        appState.toggleFilterTag("beach")
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])

        appState.toggleServiceFilter(.untagged)  // overrides the tag filter
        #expect(appState.filteredFiles.map(\.fileName) == ["b.mp4"])

        appState.toggleServiceFilter(.invalidTagging)  // mutually exclusive: replaces
        #expect(appState.filteredFiles.map(\.fileName) == ["c.mp4"])

        appState.toggleServiceFilter(.skipped)
        #expect(appState.filteredFiles.map(\.fileName) == ["x.jpg"])

        appState.toggleServiceFilter(.skipped)  // off → tag filter restored
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])

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

        // Each `select` launches its own background re-scan; await each before the next so
        // no intermediate task is left running to touch a torn-down model after the body.
        appState.select(p1)
        await appState.updateTask?.value
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])  // restored filter

        appState.select(p2)
        await appState.updateTask?.value
        #expect(appState.filteredFiles.map(\.fileName) == ["c.mp4"])  // no filter

        appState.select(p1)
        await appState.updateTask?.value
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])  // restored again
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
        appState.select(playlist)

        // Filter by "beach" and remember it as a saved search.
        appState.toggleFilterTag("beach")
        appState.saveCurrentSearch()
        #expect(appState.filteredFiles.count == 2)

        let error = await appState.renameTagAcrossPlaylist(playlist, from: "beach", to: "shore")

        #expect(error == nil)
        // The active filter and the saved search follow the rename rather than pointing
        // at the now-nonexistent "beach", so the filtered list stays populated.
        #expect(playlist.filterState.selectedTags == ["shore"])
        #expect(playlist.savedSearches.first?.tags == ["shore"])
        #expect(appState.filteredFiles.count == 2)

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
        appState.select(playlist)
        playlist.savedSearches = [
            SavedSearch(tags: ["beach"], mode: .or),
            SavedSearch(tags: ["beach", "sun"], mode: .or),
        ]

        appState.setFilterMode(.or)
        appState.toggleFilterTag("beach")
        appState.toggleFilterTag("sun")
        #expect(appState.filteredFiles.count == 2)

        await appState.removeTagAcrossPlaylist(playlist, tag: "beach")

        // The removed tag is gone from the active filter; the beach-only saved search is
        // dropped (no tags left) and the combined one keeps only "sun".
        #expect(playlist.filterState.selectedTags == ["sun"])
        #expect(playlist.savedSearches == [SavedSearch(tags: ["sun"], mode: .or)])
        #expect(appState.filteredFiles.count == 1)   // only the file that still has "sun"

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
        appState.select(playlist)

        appState.toggleFilterTag("beach")
        appState.saveCurrentSearch()
        appState.clearTagFilter()
        appState.toggleFilterTag("sun")
        appState.saveCurrentSearch()

        #expect(playlist.savedSearches.count == 2)
        #expect(playlist.savedSearches.first?.tags == ["sun"])

        // Re-applying the older one recalls it and moves it to the top (no dupe).
        appState.applySavedSearch(SavedSearch(tags: ["beach"], mode: .and))
        #expect(playlist.filterState.selectedTags == ["beach"])
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])
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

    @Test func horizontalArrowInListIsConsumedWithoutChangingSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", order: 0, to: playlist, in: context)
        addFile("b.mp4", order: 1, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.selectedPlaylist = playlist
        appState.recomputeFilteredFiles()

        // List view (one column), nothing selected: a left/right key has no axis to
        // move along, so it is swallowed (no beep) without selecting a file.
        let consumed = appState.moveFileSelection(.left)

        #expect(consumed)
        #expect(appState.selectedFileIDs.isEmpty)
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
        appState.selectedPlaylist = playlist
        appState.recomputeFilteredFiles()
        appState.fileGridColumns = 3
        let files = appState.filteredFiles

        // Top-left cell selected: moving up (−3 → row −1) and left (−1 → off the row start)
        // both fall off the grid. The key is still consumed (no beep) but the selection
        // is held in place rather than cleared or wrapped.
        appState.selectedFileIDs = [files[0].id]
        #expect(appState.moveFileSelection(.up))
        #expect(appState.selectedFileIDs == [files[0].id])
        #expect(appState.moveFileSelection(.left))
        #expect(appState.selectedFileIDs == [files[0].id])

        // Bottom-right cell: moving down (+3) and right (+1) both run past the last index.
        appState.selectedFileIDs = [files[5].id]
        #expect(appState.moveFileSelection(.down))
        #expect(appState.selectedFileIDs == [files[5].id])
        #expect(appState.moveFileSelection(.right))
        #expect(appState.selectedFileIDs == [files[5].id])
    }

    @Test func saveCurrentSearchIsANoOpWithAnEmptyFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.selectedPlaylist = playlist

        // No tags selected → nothing to remember.
        appState.saveCurrentSearch()
        #expect(playlist.savedSearches.isEmpty)
    }

    @Test func saveCurrentSearchCapsRecentsAtTen() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.selectedPlaylist = playlist
        appState.recomputeFilteredFiles()

        // Remember twelve distinct searches; only the ten most recent survive, newest first.
        for i in 0..<12 {
            appState.clearTagFilter()
            appState.toggleFilterTag("t\(i)")
            appState.saveCurrentSearch()
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
        appState.selectedPlaylist = playlist
        appState.pendingManagerDelete = [a]

        // The re-scan prunes "a.mp4"; the pending delete that targeted it must be
        // cleared so confirming can't dereference the destroyed model.
        await appState.update(playlist)

        #expect(appState.pendingManagerDelete.isEmpty)
    }

    private var emptyResult: ScanResult {
        ScanResult(files: [], counts: [:], dominantType: nil)
    }
}
