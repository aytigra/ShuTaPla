//
//  PlaylistsVersionTests.swift
//  ShuTaPlaTests
//
//  `AppState.playlistsVersion` — the signal the two sidebar lists derive against instead of a live
//  `@Query<Playlist>`. Its worth is entirely in where it does and does not move: every mutation
//  that changes a visible row (the playlist set, its order, a label, a file count) must bump it, or
//  a list goes stale; the routine saves that made the gallery storm (a filter toggle, the ~5s
//  position write) must not, or the storm comes back through the signal.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct PlaylistsVersionTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A playlist backed by a real temp folder, so paths that resolve the bookmark (delete, file
    /// ops) work. The caller keeps `dir` alive for the test body.
    private func makePlaylist(
        _ name: String,
        in context: ModelContext,
        at dir: URL,
        sortOrder: Int = 0
    ) throws -> Playlist {
        let playlist = Playlist(
            name: name,
            folderBookmark: try BookmarkService.makeBookmark(for: dir),
            folderPath: dir.path,
            mediaType: .video,
            sortOrder: sortOrder
        )
        context.insert(playlist)
        return playlist
    }

    // MARK: - Paths that must bump

    @Test func creatingAPlaylistBumps() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        appState.makePlaylist(
            name: "Clips",
            bookmark: try BookmarkService.makeBookmark(for: dir),
            folderPath: dir.path,
            scan: emptyResult,
            mediaType: .video
        )
        await appState.updateTask?.value   // drain the create derivation before the container dies

        #expect(appState.playlistsVersion != before)
    }

    @Test func renamingAPlaylistBumps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("Before", in: context, at: dir)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        appState.rename(playlist, to: "After")

        #expect(appState.playlistsVersion != before)
    }

    /// A rejected rename changes no row, so it must leave the signal alone.
    @Test func rejectedRenameDoesNotBump() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("Before", in: context, at: dir)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        appState.rename(playlist, to: "   ")

        #expect(appState.playlistsVersion == before)
    }

    @Test func reorderingBumps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makePlaylist("A", in: context, at: dir, sortOrder: 0)
        let second = try makePlaylist("B", in: context, at: dir, sortOrder: 1)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        appState.reorder([first, second], fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(appState.playlistsVersion != before)
    }

    @Test func deletingAPlaylistBumps() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("Doomed", in: context, at: dir)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        await appState.delete(playlist)

        #expect(appState.playlistsVersion != before)
    }

    /// Rows show `fileCount`, so a file leaving the playlist has to move the signal — the count is
    /// a `fetchCount` in a computed property and is not Observation-tracked on its own.
    @Test func deletingFilesBumps() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("P", in: context, at: dir)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        _ = await appState.deleteFiles([file])

        #expect(appState.playlistsVersion != before)
    }

    /// The badge's own accessor, not just the signal: a trashed file has to leave the count
    /// `PlaylistRowBadge` reads, or the bump wakes a badge that still shows the old number.
    @Test func deletingFilesDropsTheBadgeCount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("P", in: context, at: dir)
        let doomed = insertFile("a.mp4", order: 0, to: playlist, in: context)
        insertFile("b.mp4", order: 1, to: playlist, in: context)
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        #expect(appState.fileCount(of: playlist) == 2)

        _ = await appState.deleteFiles([doomed])

        #expect(appState.fileCount(of: playlist) == 1)
    }

    /// A re-scan that prunes and appends changes the count the same way a delete does.
    @Test func appliedRescanBumps() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = ScanResult(files: [scanned("a.mp4", .video)], counts: [.video: 1], dominantType: .video)
        let appState = AppState(
            modelContext: context,
            fileSystem: StubFileSystem(result: result, rescanResult: [scanned("a.mp4", .video), scanned("b.mp4", .video)])
        )
        guard case .created(let playlist) = await appState.addPlaylist(from: dir) else {
            Issue.record("expected .created")
            return
        }
        await appState.updateTask?.value   // drain the create derivation
        let before = appState.playlistsVersion

        await appState.update(playlist)

        #expect(appState.playlistsVersion != before)
    }

    // MARK: - Paths that must not bump

    /// The storm the whole fix is about: an ordinary per-file save while the Manager is up. It
    /// changes no row a sidebar shows, so it must not wake the lists.
    @Test func aFileSaveDoesNotBump() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("P", in: context, at: dir)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        file.lastPosition = 12.5   // the ~5s position write
        try context.save()

        #expect(appState.playlistsVersion == before)
    }

    /// A filter toggle persists through the same seam a create does, but changes only what the
    /// Manager shows — never the playlist set or a file count.
    @Test func togglingAFilterDoesNotBump() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let playlist = try makePlaylist("P", in: context, at: dir)
        insertFile("a.mp4", order: 0, to: playlist, in: context)
        try context.save()
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
        let before = appState.playlistsVersion

        appState.toggleServiceFilter(.untagged, on: playlist)

        #expect(appState.playlistsVersion == before)
    }

    // MARK: - What the lists read

    /// The accessor the lists call: a plain fetch, one media type, in section order.
    @Test func playlistsAccessorReturnsOneTypeInSectionOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makePlaylist("Second", in: context, at: dir, sortOrder: 1)
        _ = try makePlaylist("First", in: context, at: dir, sortOrder: 0)
        let images = Playlist(name: "Shots", folderBookmark: Data(), folderPath: dir.path, mediaType: .image)
        context.insert(images)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        #expect(appState.playlists(ofType: .video).map(\.name) == ["First", "Second"])
        #expect(appState.playlists(ofType: .image).map(\.name) == ["Shots"])
    }

    /// The refetch is what makes a mutation visible — the snapshot has no live query behind it.
    @Test func playlistsAccessorSeesAReorder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makePlaylist("A", in: context, at: dir, sortOrder: 0)
        let second = try makePlaylist("B", in: context, at: dir, sortOrder: 1)
        let appState = AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))

        appState.reorder([first, second], fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(appState.playlists(ofType: .video).map(\.name) == ["B", "A"])
    }
}
