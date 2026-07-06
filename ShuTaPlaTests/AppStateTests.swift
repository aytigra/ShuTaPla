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
import Synchronization
@testable import ShuTaPla

// MARK: - Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShuTaPlaAppStateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func scanned(_ name: String, _ type: MediaType) -> ScannedFile {
    let (tagNames, taggingStatus) = TagParser.fields(for: name)
    return ScannedFile(
        relativePath: name, fileName: name, mediaType: type, cloudStatus: .local,
        tagNames: tagNames, taggingStatus: taggingStatus
    )
}

/// A playlist's files as the store holds them, in sort order — a store-side fetch (ignoring
/// pending changes), the way the UI reads them. The background scan writes on the scan actor's
/// own context, so after an `update` the main playlist's `files` relationship is stale; post-scan
/// assertions read this instead.
@MainActor
private func storedFiles(of playlist: Playlist) -> [PlaylistFile] {
    guard let context = playlist.modelContext else { return [] }
    let pid = playlist.persistentModelID
    var descriptor = FetchDescriptor<PlaylistFile>(
        predicate: #Predicate { $0.playlist?.persistentModelID == pid },
        sortBy: [SortDescriptor(\.sortOrder)]
    )
    descriptor.includePendingChanges = false
    return (try? context.fetch(descriptor)) ?? []
}

/// Inserts a `PlaylistFile` into a playlist for the filtering/tagging tests, saving it so it
/// appears in the store-side `managerFiles` and friends (which ignore pending changes). Shares
/// the build/insert/tag core with the other suites via `insertFile`; this wrapper adds the save.
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
    let file = insertFile(name, tags: tags, status: status, skipped: skipped, order: order, to: playlist, in: context)
    try? context.save()
    return file
}

/// Returns a canned scan result regardless of the bookmark it's handed, and a canned listing of
/// the folder's current files for re-scans (the reconcile infers removals by diffing it against
/// the playlist's own files).
private struct StubFileSystem: FileSystemProviding {
    let result: ScanResult
    var rescanResult: [ScannedFile] = []
    /// When set, `trashFiles` reports every URL as failed (a locked/permission-denied trash).
    var trashFails = false
    /// When set, `rescan` throws — the "folder unreadable, leave membership as it was" path, for
    /// tests that exercise a re-scan's side effects without it reconciling files away.
    var rescanFails = false
    /// When set, `renameFile` throws it — exercises the failure-message mapping.
    var renameError: FileSystemError?

    func scanFolder(bookmark: Data) async throws -> ScanResult { result }
    func rescan(bookmark: Data) async throws -> [ScannedFile] {
        if rescanFails { throw FileSystemError.operationFailed("folder unreadable") }
        return rescanResult
    }
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        if let renameError { throw renameError }
        return url.deletingLastPathComponent().appendingPathComponent(newName)
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

    /// `liveThumbnailFingerprints` gathers every persisted fingerprint, skips files never
    /// thumbnailed (`fingerprint == nil`), and dedupes one shared across two files — the live
    /// key set the cache's orphan sweep protects.
    @Test func liveThumbnailFingerprintsGathersPersistedOnesOnly() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        addFile("a.jpg", order: 0, to: playlist, in: context).fingerprint = "fp1"
        addFile("b.jpg", order: 1, to: playlist, in: context).fingerprint = "fp2"
        addFile("c.jpg", order: 2, to: playlist, in: context)                       // never thumbnailed → nil
        addFile("d.jpg", order: 3, to: playlist, in: context).fingerprint = "fp1"   // duplicate key
        try context.save()

        #expect(appState.liveThumbnailFingerprints() == ["fp1", "fp2"])
    }

    /// A fingerprint merged onto a record but not yet saved is still live: the gallery merges it
    /// on first display and relies on autosave to flush, so the orphan sweep must see pending
    /// changes — otherwise it deletes the thumbnails of files just viewed this session.
    @Test func liveThumbnailFingerprintsIncludesUnsavedMerges() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        let file = PlaylistFile(relativePath: "a.jpg", fileName: "a.jpg", sortOrder: 0)
        file.playlist = playlist
        context.insert(file)
        file.fingerprint = "fp-pending"       // merged on display, not yet saved

        #expect(appState.liveThumbnailFingerprints().contains("fp-pending"))
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
            files: [scanned("a.mp4", .video), scanned("b [beach].mp4", .video)],
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
        await appState.updateTask?.value   // drain the background tag derivation
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
        await appState.updateTask?.value   // drain the background tag derivation
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
        await appState.updateTask?.value   // drain the background tag derivation

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
        await appState.updateTask?.value   // drain the background tag derivation
        let skipped = playlist.files.filter(\.isSkipped)
        #expect(skipped.map(\.fileName) == ["c.jpg"])
    }

    /// Creation inserts naked `PlaylistFile` rows on the main actor for an instant UI, then derives
    /// filename tags / `tagFrequency` in the background through the same actor path Update uses.
    /// Right after `addPlaylist` the rows are present but carry no tags and no `Tag` rows exist;
    /// draining the derivation populates them, and a tag filter then matches.
    @Test func creatingPlaylistInsertsNakedRowsThenDerivesTagsInBackground() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b [beach].mp4", .video)],
            counts: [.video: 2],
            dominantType: .video
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        // Naked: the rows exist immediately, but no tags have been derived yet.
        #expect(playlist.files.count == 2)
        #expect(playlist.files.allSatisfy { $0.tags.isEmpty })
        #expect(playlist.tagFrequency.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ShuTaPla.Tag>()) == 0)

        await appState.updateTask?.value   // drain the background derivation

        // Derived: tags and frequency now reflect the filenames, and a tag filter matches.
        #expect(playlist.tagFrequency["beach"] == 1)
        appState.toggleFilterTag("beach", on: playlist)
        #expect(appState.managerFiles.map(\.fileName) == ["b [beach].mp4"])
    }

    /// A create from an all-untagged folder derives to untagged and writes no `Tag` rows.
    @Test func creatingUntaggedPlaylistDerivesUntaggedAndWritesNoTags() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b.mp4", .video)],
            counts: [.video: 2],
            dominantType: .video
        )
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        await appState.updateTask?.value

        #expect(playlist.tagFrequency.isEmpty)
        #expect(playlist.files.allSatisfy { $0.tags.isEmpty })
        #expect(try context.fetchCount(FetchDescriptor<ShuTaPla.Tag>()) == 0)
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
        // The folder now holds the survivor b.mp4 and the new c.mp4 (tagged), with a.mp4 gone
        // (absent from the listing, so the reconcile prunes it).
        let rescanResult = [scanned("b.mp4", .video), scanned("c [beach].mp4", .video)]
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: result, rescanResult: rescanResult))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        await appState.updateTask?.value   // drain the create derivation before the explicit update
        #expect(playlist.files.count == 2)
        let versionBefore = appState.sequenceVersion

        await appState.update(playlist)

        let names = Set(storedFiles(of: playlist).map(\.fileName))
        #expect(names == ["b.mp4", "c [beach].mp4"])
        // The scan rebuilds tag counts on the actor's context; `applyScanResult` refaults the held
        // playlist, so its `tagFrequency` reflects the committed counts.
        #expect(playlist.tagFrequency["beach"] == 1)
        // A committed reconcile bumps the version so the store-side file lists re-derive.
        #expect(appState.sequenceVersion != versionBefore)
    }

    /// A cancellation landing in the actor's post-diff/pre-save window must not strand a commit:
    /// the store and the UI version stay consistent (both reflect the prune, or neither does).
    /// The actor rolls back when it sees the cancellation before its save, so neither moves.
    @Test func cancelInPreSaveWindowLeavesStoreAndVersionConsistent() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b.mp4", .video)],
            counts: [.video: 2],
            dominantType: .video
        )
        // The folder now holds only b.mp4, so an applied reconcile would prune a.mp4.
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: result, rescanResult: [scanned("b.mp4", .video)])
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        await appState.updateTask?.value   // drain the create derivation before the cancellation test
        let namesBefore = Set(storedFiles(of: playlist).map(\.fileName))
        let versionBefore = appState.sequenceVersion

        // Run the update on its own task and cancel that task from the pre-save hook — landing the
        // cancellation in exactly the post-diff/pre-save window. The hook is installed synchronously
        // (Mutex, no actor hop) before the task body can run, so it is in place when the scan fires.
        let task = Task { await appState.update(playlist) }
        appState.scanActor.preSaveHook.withLock { $0 = { task.cancel() } }
        await task.value

        let storeChanged = Set(storedFiles(of: playlist).map(\.fileName)) != namesBefore
        let versionBumped = appState.sequenceVersion != versionBefore
        #expect(storeChanged == versionBumped)   // consistent: both moved, or neither did
        #expect(!storeChanged)                    // rolled back: the prune never committed
    }

    /// A failed background save surfaces like the main-actor save path: `saveError` is set, the
    /// reconcile rolls back so the prune never lands, and `sequenceVersion` stays put (nothing
    /// committed to re-derive from). Forced through the actor's save-override seam.
    @Test func updateSurfacesBackgroundSaveFailure() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let result = ScanResult(
            files: [scanned("a.mp4", .video), scanned("b.mp4", .video)],
            counts: [.video: 2],
            dominantType: .video
        )
        // The folder now holds only b.mp4, so an applied reconcile would prune a.mp4 — but the save fails.
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: result, rescanResult: [scanned("b.mp4", .video)])
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        await appState.updateTask?.value   // drain the create derivation before forcing a save failure
        let namesBefore = Set(storedFiles(of: playlist).map(\.fileName))
        let versionBefore = appState.sequenceVersion

        struct SaveFailure: Error {}
        appState.scanActor.saveOverride.withLock { $0 = { throw SaveFailure() } }
        await appState.update(playlist)

        #expect(appState.saveError != nil)                                      // surfaced, not swallowed
        #expect(Set(storedFiles(of: playlist).map(\.fileName)) == namesBefore)  // rolled back: prune never landed
        #expect(appState.sequenceVersion == versionBefore)                      // nothing committed to re-derive
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

    @Test func savedSearchesAreNotCapped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        for i in 0..<11 {
            playlist.filterState = FilterState(selectedTags: ["t\(i)"], filterMode: .and)
            appState.saveCurrentSearch(on: playlist)
        }

        #expect(playlist.savedSearches.count == 11)
    }

    /// Re-saving a filter that already exists as a saved search keeps that search (and its
    /// captured resume position) rather than replacing it with a fresh nil-resume copy.
    @Test func resavingExistingSearchKeepsItsResumePosition() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        playlist.savedSearches = [SavedSearch(tags: ["a"], mode: .and, resumeSortOrder: 4)]
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        playlist.filterState = FilterState(selectedTags: ["a"], filterMode: .and)
        appState.saveCurrentSearch(on: playlist)

        #expect(playlist.savedSearches.count == 1)                    // not duplicated
        #expect(playlist.savedSearches.first?.resumeSortOrder == 4)   // resume preserved
    }

    /// Saving a genuinely new filter still records it, starting with no resume position.
    @Test func savingNewFilterStartsWithNoResumePosition() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        playlist.filterState = FilterState(selectedTags: ["new"], filterMode: .and)
        appState.saveCurrentSearch(on: playlist)

        #expect(playlist.savedSearches.first?.tags == ["new"])
        #expect(playlist.savedSearches.first?.resumeSortOrder == nil)
    }

    @Test func renameTagPreservesSavedSearchResumePosition() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        playlist.savedSearches = [SavedSearch(tags: ["old"], mode: .and, resumeSortOrder: 3)]
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        await appState.renameTagAcrossPlaylist(playlist, from: "old", to: "new")

        #expect(playlist.savedSearches.first?.tags == ["new"])
        #expect(playlist.savedSearches.first?.resumeSortOrder == 3)
    }

    /// Deleting a tag drops every saved search that referenced it and would be left with one tag
    /// or none (its resume position goes with it, never orphaned onto a narrowed combination),
    /// keeps a search left with ≥2 tags (rewritten to the remainder, resume intact), and never
    /// touches a search that didn't reference the tag.
    @Test func removeTagDeletesSavedSearchesLeftWithAtMostOneTag() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        playlist.savedSearches = [
            SavedSearch(tags: ["gone"], mode: .and, resumeSortOrder: 1),            // → 0 tags, dropped
            SavedSearch(tags: ["gone", "a"], mode: .and, resumeSortOrder: 2),       // → 1 tag, dropped
            SavedSearch(tags: ["gone", "a", "b"], mode: .and, resumeSortOrder: 3),  // → 2 tags, kept
            SavedSearch(tags: ["a", "b"], mode: .and, resumeSortOrder: 4),          // never referenced it
        ]
        context.insert(playlist)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        await appState.removeTagAcrossPlaylist(playlist, tag: "gone")

        // Only the ≥2-tag survivor (rewritten) and the unrelated search remain, resumes intact.
        #expect(playlist.savedSearches.map(\.tags) == [["a", "b"], ["a", "b"]])
        #expect(playlist.savedSearches.map(\.resumeSortOrder) == [3, 4])
    }

    @Test func reshuffleClearsResumePositions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        playlist.unfilteredResumeSortOrder = 4
        playlist.savedSearches = [SavedSearch(tags: ["a"], mode: .and, resumeSortOrder: 2)]
        context.insert(playlist)
        let file = PlaylistFile(relativePath: "v.mp4", fileName: "v.mp4", sortOrder: 0)
        file.playlist = playlist
        context.insert(file)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.reshuffle(playlist)

        #expect(playlist.unfilteredResumeSortOrder == nil)
        #expect(playlist.savedSearches.first?.resumeSortOrder == nil)
    }

    // MARK: - Per-filter resume restore on filter change (Step 3)
    //
    // A filter change settles the (non-live here) playlist onto the incoming filter's remembered
    // position. Image playlists, never started on a channel, so no engine runs and the restore is
    // observed purely on `currentFileID` / the managed selection.

    /// A saved-and-inserted image playlist with `count` files (sortOrder 0…count-1) each carrying
    /// `tags`, returned with its files in order.
    @MainActor
    private func makeFilterPlaylist(
        count: Int, tags: [String], in context: ModelContext
    ) -> (Playlist, [PlaylistFile]) {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        let suffix = tags.isEmpty ? "" : " [\(tags.joined(separator: " "))]"
        let files = (0..<count).map {
            addFile("f\($0)\(suffix).jpg", tags: tags, status: tags.isEmpty ? .untagged : .valid,
                    order: $0, to: playlist, in: context)
        }
        return (playlist, files)
    }

    @Test func clearingFilterRestoresUnfilteredSlot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (playlist, files) = makeFilterPlaylist(count: 4, tags: ["aaa"], in: context)
        playlist.unfilteredResumeSortOrder = 2
        playlist.filterState = FilterState(selectedTags: ["aaa"], filterMode: .and)
        playlist.currentFileID = files[0].id
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.clearTagFilter(on: playlist)

        #expect(playlist.currentFileID == files[2].id)   // first file at-or-after stored order 2
    }

    @Test func applyingSavedSearchRestoresItsSlot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        // Only f0 and f2 carry "aaa", so the search's sequence is {f0, f2}.
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        let files = ["aaa", "bbb", "aaa", "bbb"].enumerated().map { index, tag in
            addFile("f\(index) [\(tag)].jpg", tags: [tag], status: .valid, order: index, to: playlist, in: context)
        }
        let search = SavedSearch(tags: ["aaa"], mode: .and, resumeSortOrder: 2)
        playlist.savedSearches = [search]
        playlist.currentFileID = files[0].id
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.applySavedSearch(search, on: playlist)

        #expect(playlist.currentFileID == files[2].id)   // first "aaa" file at-or-after order 2
    }

    @Test func restoreWrapsWhenStoredOrderPastSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (playlist, files) = makeFilterPlaylist(count: 4, tags: ["aaa"], in: context)
        playlist.unfilteredResumeSortOrder = 99   // past the last file
        playlist.filterState = FilterState(selectedTags: ["aaa"], filterMode: .and)
        playlist.currentFileID = files[1].id
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.clearTagFilter(on: playlist)

        #expect(playlist.currentFileID == files[0].id)   // wrapped to the first file
    }

    @Test func adHocFilterLeavesCursorUntouched() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (playlist, files) = makeFilterPlaylist(count: 4, tags: ["aaa"], in: context)
        playlist.currentFileID = files[1].id   // unfiltered, no slot stored
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.toggleFilterTag("aaa", on: playlist)   // ad-hoc (no matching saved search)

        #expect(playlist.activeResumeSlot == nil)
        #expect(playlist.currentFileID == files[1].id)   // still in the filtered set, cursor kept
    }

    @Test func serviceFilterRestoresNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (playlist, files) = makeFilterPlaylist(count: 4, tags: ["aaa"], in: context)
        playlist.unfilteredResumeSortOrder = 2   // the tag side has a slot; the service side must ignore it
        playlist.currentFileID = files[0].id
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.toggleServiceFilter(.untagged, on: playlist)

        #expect(playlist.currentFileID == files[0].id)   // a service filter earns no slot
    }

    @Test func filterChangeRecentersManagedSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (playlist, files) = makeFilterPlaylist(count: 4, tags: ["aaa"], in: context)
        playlist.unfilteredResumeSortOrder = 2
        playlist.filterState = FilterState(selectedTags: ["aaa"], filterMode: .and)
        playlist.currentFileID = files[0].id
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = playlist
        appState.managerSelection = [files[0].id]
        let tokenBefore = appState.scrollSelectionToken

        appState.clearTagFilter(on: playlist)

        #expect(playlist.currentFileID == files[2].id)
        #expect(appState.managerSelection == [files[2].id])   // selection follows the restored cursor
        #expect(appState.scrollSelectionToken == tokenBefore + 1)   // list re-centers
    }

    /// The contract TagSidebar's editor input depends on: the store-side `selectedManagerFiles()`
    /// yields the selected files in display (sortOrder) order — equal to filtering the whole
    /// `playlist.files` relationship and sorting it, the walk the sidebar used to do inline.
    @Test func selectedManagerFilesMatchesFilteredRelationshipInDisplayOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (playlist, files) = makeFilterPlaylist(count: 5, tags: [], in: context)
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = playlist
        // A multi-file selection given out of display order.
        appState.managerSelection = [files[3].id, files[1].id, files[4].id]

        let relationshipWalk = playlist.files
            .filter { appState.managerSelection.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(appState.selectedManagerFiles().map(\.id) == relationshipWalk.map(\.id))
        #expect(appState.selectedManagerFiles().map(\.id) == [files[1].id, files[3].id, files[4].id])
    }

    // MARK: - Per-filter resume restore — live audio channel (Step 4)
    //
    // The restore's live branch on a real engine: a filter change on a *playing* audio playlist
    // switches the engine to the restored track now, while a non-live playlist only moves the
    // cursor. The window-free `AudioPlaybackEngine` (`vo=null`) backs the channel and the files are
    // empty placeholders, so the channel never decodes — only the jump's bookkeeping is observed.

    /// A saved-and-inserted audio playlist over a real bookmarked folder of empty files, so the
    /// coordinator's scoped access resolves and a live channel can start. File `i` is named for its
    /// `tags[i]` (bracketed when tagged), and the on-disk fixtures match, so the seeded tags are
    /// exactly what the name parses to. Returns the folder too, for cleanup.
    @MainActor
    private func makeAudioPlaylist(
        tags: [[String]], in context: ModelContext
    ) throws -> (folder: (url: URL, bookmark: Data), playlist: Playlist, files: [PlaylistFile]) {
        let names = tags.enumerated().map { index, fileTags in
            fileTags.isEmpty ? "f\(index).mp3" : "f\(index) [\(fileTags.joined(separator: " "))].mp3"
        }
        let folder = try makeBookmarkedFolder(names)
        let playlist = Playlist(name: "Tunes", folderBookmark: folder.bookmark,
                                folderPath: folder.url.path(percentEncoded: false), mediaType: .audio)
        context.insert(playlist)
        let files = zip(names, tags).enumerated().map { index, pair in
            addFile(pair.0, tags: pair.1, status: pair.1.isEmpty ? .untagged : .valid,
                    order: index, to: playlist, in: context)
        }
        return (folder, playlist, files)
    }

    @Test func liveAudioJumpsToRestoredFileOnFilterChange() throws {
        let container = try makeContainer()
        let context = container.mainContext
        // The search's sequence is {f1, f2}; resume order 2 lands on f2.
        let (folder, playlist, files) = try makeAudioPlaylist(
            tags: [["xxx"], ["aaa"], ["aaa"], ["xxx"]], in: context)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let search = SavedSearch(tags: ["aaa"], mode: .and, resumeSortOrder: 2)
        playlist.savedSearches = [search]
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.coordinator.play(playlist)               // unfiltered → starts on f0
        #expect(appState.coordinator.audioCurrentFile?.id == files[0].id)

        appState.applySavedSearch(search, on: playlist)

        #expect(playlist.currentFileID == files[2].id)
        #expect(appState.coordinator.audioCurrentFile?.id == files[2].id)   // the engine switched tracks
        #expect(appState.coordinator.liveAudioPlaylist === playlist)        // still live
    }

    @Test func nonLiveAudioFilterChangeOnlyMovesCursor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (folder, playlist, files) = try makeAudioPlaylist(
            tags: [["xxx"], ["aaa"], ["aaa"], ["xxx"]], in: context)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let search = SavedSearch(tags: ["aaa"], mode: .and, resumeSortOrder: 2)
        playlist.savedSearches = [search]
        playlist.currentFileID = files[0].id
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.applySavedSearch(search, on: playlist)   // never played → not live

        #expect(playlist.currentFileID == files[2].id)    // cursor restored
        #expect(appState.coordinator.liveAudioPlaylist == nil)    // no channel started
        #expect(appState.coordinator.audioCurrentFile == nil)     // engine untouched
    }

    @Test func liftingAnEmptyingFilterReloadsTheStrandedVisualChannel() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeBookmarkedFolder(["f0.jpg", "f1.jpg"])
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let image = Playlist(name: "Pics", folderBookmark: folder.bookmark,
                             folderPath: folder.url.path(percentEncoded: false), mediaType: .image)
        context.insert(image)
        let f0 = addFile("f0.jpg", order: 0, to: image, in: context)
        addFile("f1.jpg", order: 1, to: image, in: context)
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.coordinator.play(image)                       // unfiltered → starts on f0
        #expect(appState.coordinator.visualCurrentFile?.id == f0.id)

        // A filter that matches nothing empties the sequence: the visual channel stays live but its
        // engine is unloaded (the "no files" placeholder). `currentFileID` still points at f0.
        appState.toggleFilterTag("nomatch", on: image)
        #expect(appState.coordinator.liveVisualPlaylist === image)
        #expect(appState.coordinator.visualCurrentFile == nil)

        // Lifting the filter restores the unfiltered slot, whose target (f0) equals the untouched
        // `currentFileID`. The restore must still reload the emptied engine rather than leave the
        // channel stranded on its placeholder.
        appState.clearTagFilter(on: image)
        #expect(appState.coordinator.visualCurrentFile?.id == f0.id)
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
        #expect(file.tagNames == ["beach"])
        #expect(file.taggingStatus == .valid)
    }

    @Test(arguments: [
        (FileSystemError.invalidName, "That name isn't valid."),
        (FileSystemError.nameCollision, "A file with that name already exists."),
        (FileSystemError.fileNotFound, "The file no longer exists on disk."),
        (FileSystemError.operationFailed("boom"), "Rename failed: boom"),
    ])
    func renameFileSurfacesFailureMessage(error: FileSystemError, expected: String) async throws {
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
        var stub = StubFileSystem(result: emptyResult)
        stub.renameError = error
        let appState = AppState(modelContext: context, fileSystem: stub)

        let message = await appState.renameFile(file, to: "new.mp4")

        #expect(message == expected)
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

    // MARK: - Identifier-based file lists (Task 17 Stage C)

    @Test func managerFileIDsAreTheOrderedStoreSequenceResolvedByFileFor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a.mp4", order: 0, to: playlist, in: context)
        addFile("b.mp4", order: 1, to: playlist, in: context)
        addFile("c.mp4", order: 2, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = playlist

        // The accessor returns identifiers, not models — the same ordered sequence the store
        // derives — and `file(for:)` resolves each on demand (the lazy render path).
        let ids = appState.managerFileIDs
        #expect(ids == context.displaySequence(of: playlist))
        #expect(ids.compactMap { appState.file(for: $0)?.fileName } == ["a.mp4", "b.mp4", "c.mp4"])
    }

    /// The memoized sequence accessors re-derive exactly when the store-side result can change:
    /// a `sequenceVersion` bump (any persisted membership/order/filter mutation) or a switch of
    /// the accessor's source playlist. Within one version-and-playlist they reuse the last result
    /// instead of re-fetching. Passes on the un-memoized accessor too (which always refetches), so
    /// it pins the contract the memoization must preserve.
    @Test func sequenceAccessorsReDeriveOnVersionBumpAndPlaylistSwitch() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .video, sortOrder: 0)
        let b = Playlist(name: "B", folderBookmark: Data(), folderPath: "/b", mediaType: .video, sortOrder: 1)
        context.insert(a)
        context.insert(b)
        addFile("a1.mp4", order: 0, to: a, in: context)
        addFile("a2.mp4", order: 1, to: a, in: context)
        addFile("b1.mp4", order: 0, to: b, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = a

        // Repeated reads at the same version and playlist agree with the store derivation.
        #expect(appState.managerFiles.map(\.fileName) == ["a1.mp4", "a2.mp4"])
        #expect(appState.managerFiles.map(\.fileName) == ["a1.mp4", "a2.mp4"])

        // A saved insert visible only after a version bump (the mutation contract) re-derives.
        addFile("a3.mp4", order: 2, to: a, in: context)
        appState.sequenceVersion &+= 1
        #expect(appState.managerFiles.map(\.fileName) == ["a1.mp4", "a2.mp4", "a3.mp4"])

        // Switching the managed playlist re-derives without a version bump (keyed on identity)…
        appState.managedPlaylist = b
        #expect(appState.managerFiles.map(\.fileName) == ["b1.mp4"])

        // …and switching back returns A's current sequence, not a stale slot.
        appState.managedPlaylist = a
        #expect(appState.managerFiles.map(\.fileName) == ["a1.mp4", "a2.mp4", "a3.mp4"])
    }

    // MARK: - Find duplicates (Stage 3)

    /// `duplicateSequence` keeps only files whose fingerprint recurs (count ≥ 2), drops singletons
    /// and never-thumbnailed (`nil`) files, and groups each duplicate set adjacently, ordered by
    /// fingerprint.
    @Test func duplicateSequenceGroupsRecurringFingerprintsAndDropsSingletons() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        addFile("a.jpg", order: 0, to: playlist, in: context).fingerprint = "fp1"
        addFile("b.jpg", order: 1, to: playlist, in: context).fingerprint = "fp2"
        addFile("c.jpg", order: 2, to: playlist, in: context).fingerprint = "fp1"   // pairs with a
        addFile("d.jpg", order: 3, to: playlist, in: context)                       // nil → dropped
        addFile("e.jpg", order: 4, to: playlist, in: context).fingerprint = "fp2"   // pairs with b
        addFile("f.jpg", order: 5, to: playlist, in: context).fingerprint = "fp3"   // singleton → dropped
        try context.save()

        let names = context.duplicateSequence(of: playlist)
            .compactMap { context.model(for: $0) as? PlaylistFile }.map(\.fileName)
        #expect(names == ["a.jpg", "c.jpg", "b.jpg", "e.jpg"])
    }

    /// Entering the mode swaps `managerFileIDs` from the display sequence to the duplicate grouping,
    /// clears the selection (made against the other sequence), and bumps the version so the list
    /// re-derives; leaving restores the display sequence. A no-op call neither resets nor bumps.
    @Test func duplicateSearchModeSwapsManagerSequenceAndResetsSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        let a = addFile("a.jpg", order: 0, to: playlist, in: context); a.fingerprint = "fp1"
        let b = addFile("b.jpg", order: 1, to: playlist, in: context); b.fingerprint = "fp2"
        addFile("c.jpg", order: 2, to: playlist, in: context).fingerprint = "fp1"   // pairs with a
        addFile("d.jpg", order: 3, to: playlist, in: context)                       // nil → not a duplicate
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = playlist
        appState.managerSelection = [a.id, b.id]

        #expect(appState.managerFiles.map(\.fileName) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        let versionBefore = appState.sequenceVersion

        appState.setDuplicateSearch(true)
        #expect(appState.duplicateSearchActive)
        #expect(appState.managerSelection.isEmpty)                       // selection reset on entry
        #expect(appState.sequenceVersion > versionBefore)                // re-derives the list
        #expect(appState.managerFiles.map(\.fileName) == ["a.jpg", "c.jpg"])   // only the fp1 pair

        appState.setDuplicateSearch(false)
        #expect(!appState.duplicateSearchActive)
        #expect(appState.managerFiles.map(\.fileName) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])

        // A no-op call (already inactive) leaves the selection and version untouched.
        appState.managerSelection = [a.id]
        let versionRest = appState.sequenceVersion
        appState.setDuplicateSearch(false)
        #expect(appState.managerSelection == [a.id])
        #expect(appState.sequenceVersion == versionRest)
    }

    /// Deleting a duplicate while the mode is active recomputes the grouping *within* the mode: the
    /// trashed file drops, and a fingerprint now down to a single copy stops recurring so its group
    /// dissolves — without leaving the mode. The crux the tool exists for.
    @Test func deletingInDuplicateModeRecomputesAndCollapsesWithoutExiting() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .image)
        context.insert(playlist)
        let a = addFile("a.jpg", order: 0, to: playlist, in: context); a.fingerprint = "AA"
        addFile("b.jpg", order: 1, to: playlist, in: context).fingerprint = "AA"   // pairs with a
        addFile("c.jpg", order: 2, to: playlist, in: context).fingerprint = "BB"
        addFile("d.jpg", order: 3, to: playlist, in: context).fingerprint = "BB"   // pairs with c
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = playlist

        appState.setDuplicateSearch(true)
        #expect(appState.managerFiles.map(\.fileName) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])

        let error = await appState.deleteFiles([a])
        #expect(error == nil)
        #expect(appState.duplicateSearchActive)                          // still in the mode
        #expect(appState.managerFiles.map(\.fileName) == ["c.jpg", "d.jpg"])   // AA collapsed to one → gone
    }

    /// A normal filter interaction returns the Manager center to the ordinary display sequence —
    /// the documented way out of the mode (unlike a delete, which recomputes within it).
    @Test func filterEditExitsDuplicateSearch() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        addFile("a.jpg", order: 0, to: playlist, in: context).fingerprint = "fp1"
        addFile("b.jpg", order: 1, to: playlist, in: context).fingerprint = "fp1"
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = playlist
        appState.setDuplicateSearch(true)
        #expect(appState.duplicateSearchActive)

        appState.clearTagFilter(on: playlist)   // any filter interaction returns to the ordinary view

        #expect(!appState.duplicateSearchActive)
        #expect(appState.managerFileIDs == context.displaySequence(of: playlist))
    }

    /// `findDuplicates` saves before entering the mode: fingerprints merged onto records while
    /// scrolling (and not yet flushed by autosave) must be visible to `duplicateSequence`, whose
    /// fetch ignores pending changes — otherwise a just-viewed pair would be invisible to the tool.
    @Test func findDuplicatesFlushesPendingFingerprintsBeforeEntering() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        let a = addFile("a.jpg", order: 0, to: playlist, in: context)
        let b = addFile("b.jpg", order: 1, to: playlist, in: context)
        try context.save()   // saved with no fingerprints
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }
        appState.managedPlaylist = playlist   // pre-managed, so findDuplicates skips setManaged

        // Two matching fingerprints merged on display but not yet saved.
        a.fingerprint = "dup"
        b.fingerprint = "dup"

        appState.findDuplicates(in: playlist)
        #expect(appState.duplicateSearchActive)
        #expect(appState.managerFiles.map(\.fileName) == ["a.jpg", "b.jpg"])   // the flushed pair is visible
    }

    // MARK: - Filtering (Task 7)

    @Test func tagFilterAppliesAndOrCorrectly() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a [beach sun].mp4", tags: ["beach", "sun"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b [beach].mp4", tags: ["beach"], status: .valid, order: 1, to: playlist, in: context)
        addFile("c.mp4", order: 2, to: playlist, in: context)
        // This test exercises filtering, not scanning; a failing rescan keeps the seeded files intact
        // (the default empty listing would otherwise prune them all, making the assertions depend on
        // running before the trailing drain).
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, rescanFails: true))
        appState.manage(playlist)

        appState.toggleFilterTag("beach", on: playlist)
        #expect(Set(appState.managerFiles.map(\.fileName)) == ["a [beach sun].mp4", "b [beach].mp4"])

        appState.toggleFilterTag("sun", on: playlist)  // AND beach + sun
        #expect(appState.managerFiles.map(\.fileName) == ["a [beach sun].mp4"])

        appState.setFilterMode(.or, on: playlist)       // beach OR sun
        #expect(Set(appState.managerFiles.map(\.fileName)) == ["a [beach sun].mp4", "b [beach].mp4"])

        await appState.updateTask?.value
    }

    /// Regression: a store carried across the lightweight schema migration has files whose
    /// `tags` relationship is empty even though their filenames still carry tags — the chips
    /// render from the filename, so the tags look present, but the filter (a store predicate
    /// over the relationship) finds nothing. The managed-playlist scan must re-mirror the
    /// filename-derived tags and tagging status onto the columns the filter queries.
    @Test func managedScanRemirrorsFilenameTagsOntoTheRelationship() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        // Tagged filenames but an empty `tags` relationship and default tagging status — the
        // shape a lightweight migration leaves behind (the derived columns dropped, the names intact).
        addFile("a [beach].jpg", tags: [], status: .untagged, order: 0, to: playlist, in: context)
        addFile("b [beach sunny].jpg", tags: [], status: .untagged, order: 1, to: playlist, in: context)
        addFile("c.jpg", tags: [], status: .untagged, order: 2, to: playlist, in: context)
        // The folder on disk still holds the same tagged filenames; the scan derives their tags
        // (off-main) and the apply re-mirrors them onto the empty relationship.
        let rescanResult = [
            scanned("a [beach].jpg", .image),
            scanned("b [beach sunny].jpg", .image),
            scanned("c.jpg", .image),
        ]
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, rescanResult: rescanResult))

        // Managing the playlist runs the background scan, which reconciles the relationship.
        appState.manage(playlist)
        await appState.updateTask?.value

        // The filter dropdown's known tags come back, and filtering by a re-mirrored tag matches.
        #expect(playlist.tagFrequency["beach"] == 2)
        appState.toggleFilterTag("beach", on: playlist)
        #expect(Set(appState.managerFiles.map(\.fileName)) == ["a [beach].jpg", "b [beach sunny].jpg"])
    }

    /// A scan that drops a tag from every filename it appeared in leaves its `Tag` row referencing
    /// no files; the scan's cleanup deletes such orphans. But `Tag` is shared many-to-many across
    /// playlists, so a tag another playlist's files still carry is kept — cleanup keys on the
    /// global `files`, never per-playlist.
    @Test func scanDeletesTagsOrphanedFromEveryFilenameButKeepsSharedOnes() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .image)
        let b = Playlist(name: "B", folderBookmark: Data(), folderPath: "/b", mediaType: .image)
        context.insert(a)
        context.insert(b)
        // A's file carries "gone" and "shared" on the relationship, but its on-disk name dropped
        // both. B's file still carries "shared" in its filename — the same shared `Tag` row.
        addFile("x.jpg", tags: ["gone", "shared"], status: .valid, order: 0, to: a, in: context)
        addFile("y [shared].jpg", tags: ["shared"], status: .valid, order: 0, to: b, in: context)

        // Scanning A re-derives x.jpg to untagged, orphaning "gone" globally (only A had it) while
        // "shared" stays on B's file.
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: emptyResult, rescanResult: [scanned("x.jpg", .image)])
        )
        await appState.update(a)

        func tagExists(_ normalized: String) throws -> Bool {
            var descriptor = FetchDescriptor<ShuTaPla.Tag>(predicate: #Predicate { $0.normalizedName == normalized })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first != nil
        }
        #expect(try !tagExists("gone"))     // dropped from every filename → cleaned up
        #expect(try tagExists("shared"))    // still carried by B's file → kept
    }

    @Test func serviceFilterOverridesAndRestoresTagFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b.mp4", status: .untagged, order: 1, to: playlist, in: context)
        addFile("c [ab].mp4", status: .invalid, order: 2, to: playlist, in: context)
        addFile("x.jpg", status: .untagged, skipped: true, order: 3, to: playlist, in: context)
        // This test exercises filtering, not scanning; a failing rescan keeps the seeded files intact
        // (the default empty listing would otherwise prune them all, making the assertions depend on
        // running before the trailing drain).
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, rescanFails: true))
        appState.manage(playlist)

        appState.toggleFilterTag("beach", on: playlist)
        #expect(appState.managerFiles.map(\.fileName) == ["a [beach].mp4"])

        appState.toggleServiceFilter(.untagged, on: playlist)  // overrides the tag filter
        #expect(appState.managerFiles.map(\.fileName) == ["b.mp4"])

        appState.toggleServiceFilter(.invalidTagging, on: playlist)  // mutually exclusive: replaces
        #expect(appState.managerFiles.map(\.fileName) == ["c [ab].mp4"])

        appState.toggleServiceFilter(.skipped, on: playlist)
        #expect(appState.managerFiles.map(\.fileName) == ["x.jpg"])

        appState.toggleServiceFilter(.skipped, on: playlist)  // off → tag filter restored
        #expect(appState.managerFiles.map(\.fileName) == ["a [beach].mp4"])

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
        addFile("a [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: p1, in: context)
        addFile("b.mp4", order: 1, to: p1, in: context)
        addFile("c.mp4", order: 0, to: p2, in: context)
        // This test is about filter restoration on switch, not scanning; a failing rescan keeps each
        // playlist's seeded files intact (an empty listing would otherwise prune them all).
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, rescanFails: true))

        // Each `manage` launches its own background re-scan; await each before the next so
        // no intermediate task is left running to touch a torn-down model after the body.
        appState.manage(p1)
        await appState.updateTask?.value
        #expect(appState.managerFiles.map(\.fileName) == ["a [beach].mp4"])  // restored filter

        appState.manage(p2)
        await appState.updateTask?.value
        #expect(appState.managerFiles.map(\.fileName) == ["c.mp4"])  // no filter

        appState.manage(p1)
        await appState.updateTask?.value
        #expect(appState.managerFiles.map(\.fileName) == ["a [beach].mp4"])  // restored again
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
        #expect(a.tagNames == ["beach"])
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
        #expect(a.tagNames == ["shore"])
        #expect(b.tagNames == ["shore"])
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

    @Test func setTagFilterReplacesTheWholeFilterWithTheClickedTag() async throws {
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

        // A pre-existing multi-tag AND filter that the click must replace outright.
        appState.setFilterMode(.and, on: playlist)
        appState.toggleFilterTag("beach", on: playlist)
        appState.toggleFilterTag("sun", on: playlist)
        #expect(appState.managerFiles.count == 1)

        appState.setTagFilter(to: "beach", on: playlist)

        #expect(playlist.filterState.selectedTags == ["beach"])   // replaced, not appended
        #expect(appState.managerFiles.count == 2)                 // both "beach" files now show

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
            SavedSearch(tags: ["beach", "sun", "sea"], mode: .or),
        ]

        appState.setFilterMode(.or, on: playlist)
        appState.toggleFilterTag("beach", on: playlist)
        appState.toggleFilterTag("sun", on: playlist)
        #expect(appState.managerFiles.count == 2)

        await appState.removeTagAcrossPlaylist(playlist, tag: "beach")

        // The removed tag is gone from the active filter. The saved searches left with ≤1 tag
        // (beach-only → none, beach+sun → just "sun") are dropped; only the three-tag one
        // survives, rewritten to the remaining two.
        #expect(playlist.filterState.selectedTags == ["sun"])
        #expect(playlist.savedSearches.count == 1)
        #expect(playlist.savedSearches.first?.tags == ["sun", "sea"])
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

        appState.requestPlayerDelete(file)
        appState.confirmConfirmation()

        // The fire-and-forget trash fails, so the player reports the message instead of
        // silently advancing, and the file stays in the playlist.
        var waited = 0
        while appState.confirmationError == nil && waited < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(appState.confirmationError != nil)
        #expect(file.playlist === playlist)
        #expect(playlist.files.contains { $0 === file })
    }

    // MARK: - Saved searches (Task 7)

    @Test func savedSearchSavesRecallsAndMovesToTop() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("a [beach sun].mp4", tags: ["beach", "sun"], status: .valid, order: 0, to: playlist, in: context)
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
        #expect(appState.managerFiles.map(\.fileName) == ["a [beach sun].mp4"])
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
        // The folder holds the known a.mp4 plus one not-yet-known file; a scan reconciles to it.
        let rescanResult = [scanned("a.mp4", .video), scanned("new.mp4", .video)]
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, rescanResult: rescanResult))

        appState.manage(playlist)
        let firstScan = appState.updateTask
        await appState.updateTask?.value
        #expect(storedFiles(of: playlist).count == 2)        // a.mp4 + the discovered new.mp4

        // Re-clicking the already-selected row re-reads the folder — the automatic Update, the
        // reason there's no dedicated control — so it spawns a fresh scan rather than no-op'ing.
        // The folder is unchanged, so the re-scan reconciles to the same set by relative path
        // without duplicating the already-present files.
        appState.manage(playlist)
        #expect(appState.updateTask != firstScan)
        await appState.updateTask?.value
        #expect(storedFiles(of: playlist).count == 2)
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

    @Test func rescanRemovalClearsPendingDeleteForThatFile() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "P", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        context.insert(playlist)
        let a = addFile("a.mp4", order: 0, to: playlist, in: context)
        // The folder is now empty, so the reconcile prunes a.mp4.
        let stub = StubFileSystem(result: emptyResult, rescanResult: [])
        let appState = AppState(modelContext: context, fileSystem: stub)
        appState.managedPlaylist = playlist
        appState.pendingConfirmation = .managerDelete([a])

        // The re-scan prunes "a.mp4"; the pending delete that targeted it must be
        // cleared so confirming can't dereference the destroyed model.
        await appState.update(playlist)

        #expect(appState.pendingConfirmation == nil)
    }

    @Test func managerDeleteRequestModelsOnePendingConfirmation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        let a = addFile("a.mp4", order: 0, to: playlist, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        appState.managedPlaylist = playlist

        // The request models exactly one pending confirmation carrying its target.
        appState.requestManagerDelete([a])
        #expect(appState.pendingConfirmation?.managerDeleteFiles?.map(\.id) == [a.id])

        // Cancelling clears it.
        appState.cancelConfirmation()
        #expect(appState.pendingConfirmation == nil)
    }

    // MARK: - Audio overlay (Task 15)

    @Test func audioFilterTogglesAndRecomputesIndependently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        addFile("1 [jazz mellow].mp3", tags: ["jazz", "mellow"], status: .valid, order: 0, to: audio, in: context)
        addFile("2 [jazz].mp3", tags: ["jazz"], status: .valid, order: 1, to: audio, in: context)
        addFile("3.mp3", order: 2, to: audio, in: context)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.remember(audio)   // occupy the audio channel slot; channel files derive from it
        #expect(appState.audioChannelFiles.count == 3)

        appState.toggleFilterTag("jazz", on: audio)
        #expect(Set(appState.audioChannelFiles.map(\.fileName)) == ["1 [jazz mellow].mp3", "2 [jazz].mp3"])

        appState.toggleFilterTag("mellow", on: audio)       // AND jazz + mellow
        #expect(appState.audioChannelFiles.map(\.fileName) == ["1 [jazz mellow].mp3"])

        appState.setFilterMode(.or, on: audio)              // jazz OR mellow
        #expect(Set(appState.audioChannelFiles.map(\.fileName)) == ["1 [jazz mellow].mp3", "2 [jazz].mp3"])

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
        // visual delete confirmation; otherwise the engine stays on the deleted file.
        appState.requestAudioDelete(first)
        appState.confirmConfirmation()

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
        appState.confirmConfirmation()

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
        // The re-scan reports the on-screen file gone from disk, leaving only "2.jpg".
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: emptyResult, rescanResult: [scanned("2.jpg", .image)])
        )
        defer { appState.coordinator.shutdown() }

        // Play the image playlist on the visual channel (the image engine has no libmpv, so this
        // is trap-safe).
        appState.coordinator.play(image)
        #expect(image.currentFileID == first.id)

        // The background Update prunes the playing file; apply() must advance the visual channel
        // off it — the symmetric counterpart to the audio reconcile — not leave the engine on a
        // destroyed model.
        await appState.update(image)

        #expect(storedFiles(of: image).map(\.fileName) == ["2.jpg"])
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
        // The folder holds the known a.mp3 plus a not-yet-known new.mp3 (the scan reconciles to it).
        let rescanResult = [scanned("a.mp3", .audio), scanned("new.mp3", .audio)]
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult, rescanResult: rescanResult))
        defer { appState.coordinator.shutdown() }

        let tokenBefore = appState.audioScrollToken
        appState.playOnAudioChannel(audio)
        #expect(appState.audioChannelPlaylist === audio)
        #expect(appState.coordinator.liveAudioPlaylist === audio)   // a new selection starts playing
        #expect(appState.audioScrollToken > tokenBefore)        // asks the file list to re-center
        await appState.updateTask?.value
        #expect(storedFiles(of: audio).count == 2)              // re-read the folder

        // Re-selecting the active audio playlist re-reads the folder again (no dedicated control)
        // and re-centers the list once more. The folder is unchanged, so the re-scan reconciles to
        // the same set by relative path without duplicating the already-present files.
        let tokenAfterFirst = appState.audioScrollToken
        appState.playOnAudioChannel(audio)
        #expect(appState.audioScrollToken > tokenAfterFirst)
        await appState.updateTask?.value
        #expect(storedFiles(of: audio).count == 2)
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
        await appState.updateTask?.value   // drain the background tag derivation

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
        await appState.updateTask?.value   // drain the background tag derivation

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
        // The re-scan prunes the track that's currently playing, leaving only "2.mp3".
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: emptyResult, rescanResult: [scanned("2.mp3", .audio)])
        )
        defer { appState.coordinator.shutdown() }

        appState.startPlayback(of: audio)
        #expect(audio.currentFileID == first.id)

        await appState.update(audio)            // a re-scan that removes the playing track
        #expect(storedFiles(of: audio).count == 1)
        #expect(audio.currentFileID == secondID)   // reconciled off the pruned track
    }

    @Test func audioRescanRemovalClearsPendingAudioDelete() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let audio = Playlist(name: "A", folderBookmark: Data(), folderPath: "/a", mediaType: .audio)
        context.insert(audio)
        let doomed = addFile("1.mp3", order: 0, to: audio, in: context)
        addFile("2.mp3", order: 1, to: audio, in: context)
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: emptyResult, rescanResult: [scanned("2.mp3", .audio)])
        )

        // A trash confirmation pointing at a file the re-scan prunes must not survive to act
        // on a destroyed model.
        appState.requestAudioDelete(doomed)
        await appState.update(audio)
        #expect(appState.pendingConfirmation == nil)
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

        appState.remember(audio)   // loads the audio channel slot without playing

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
        let tagged = addFile("1 [jazz].mp3", tags: ["jazz"], status: .valid, order: 0, to: audio, in: context)
        addFile("2.mp3", order: 1, to: audio, in: context)
        audio.currentFileID = tagged.id
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        defer { appState.coordinator.shutdown() }

        appState.remember(audio)
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

        appState.remember(audio)

        // The audio overlay is a transport list, not a triage surface: skipped tracks are never
        // playable, so they must not appear in it, and a skipped resume track must not resolve as
        // the current (transport) track. Under the Skipped filter nothing is playable, so the list
        // is empty.
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

        // The Visual Overlay resolves its highlighted/centered file from the live visual
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
        await appState.updateTask?.value   // drain the background tag derivation
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
        await appState.updateTask?.value   // drain the background tag derivation
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
        appState.remember(env.audio)   // an audio playlist sitting in the channel

        appState.switchScope(to: .audio)
        #expect(appState.managedPlaylist === env.audio)   // synced from the audio channel slot
    }

    @Test func rememberKeepsVisualMemoriesIndependent() throws {
        let env = try makeSlotState()
        let appState = env.appState

        // Recording a video then an image leaves both remembered — the visual memories don't
        // overwrite each other (only the *playing* visual channel is mutually exclusive).
        appState.remember(env.video)
        appState.remember(env.image)
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
        #expect(t1.tagNames == ["jazz"])
        #expect(t2.tagNames == ["jazz"])
        #expect(audio.tagFrequency["jazz"] == 2)
    }

    /// A persist failure is not swallowed: `persistAndRefresh` surfaces it through `saveError` and
    /// rolls the context back, so a mutation whose save fails leaves no stale in-memory edit
    /// diverging from the (unchanged) saved store. Driven through the injectable `persist` seam,
    /// since the in-memory store's own `save` never throws.
    @Test func persistFailureSurfacesErrorAndRollsBackTheEdit() throws {
        struct SaveFailed: Error {}
        let container = try makeContainer()
        let context = container.mainContext
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: emptyResult),
            persist: { throw SaveFailed() }
        )
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        try context.save()   // baseline the rollback reverts to (a direct save, not via the seam)

        appState.toggleServiceFilter(.untagged, on: playlist)

        #expect(appState.saveError != nil)
        // The rollback discarded the pending edit at the store layer, so a later successful save
        // can't silently flush this failed change.
        #expect(context.hasChanges == false)
    }

    private var emptyResult: ScanResult {
        ScanResult(files: [], counts: [:], dominantType: nil)
    }
}
