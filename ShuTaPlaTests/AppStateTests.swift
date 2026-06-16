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

    func scanFolder(bookmark: Data) async throws -> ScanResult { result }
    func updatePlaylist(bookmark: Data, knownRelativePaths: Set<String>) async throws -> UpdateDelta {
        delta
    }
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        url.deletingLastPathComponent().appendingPathComponent(newName)
    }
    func trashFiles(_ urls: [URL]) async throws -> TrashResult { TrashResult(trashed: urls, failed: []) }
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

        appState.select(p1)
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])  // restored filter

        appState.select(p2)
        #expect(appState.filteredFiles.map(\.fileName) == ["c.mp4"])  // no filter

        appState.select(p1)
        #expect(appState.filteredFiles.map(\.fileName) == ["a.mp4"])  // restored again

        await appState.updateTask?.value
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
