//
//  SequenceStoreTests.swift
//  ShuTaPlaTests
//
//  Task 17 (Stage B) — the store-side derivation on `ModelContext`: ordered display/playback
//  identifiers and the triage counts, under no filter, each service filter, and tag AND/OR.
//  The fetches use `includePendingChanges: false`, so every scenario saves before deriving; a
//  separate case pins that an unsaved insert is not yet visible.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct SequenceStoreTests {

    /// Holds the container for the whole body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @discardableResult
    private func addFile(
        _ name: String, tags: [String] = [], status: TaggingStatus = .untagged,
        skipped: Bool = false, order: Int, to playlist: Playlist, in context: ModelContext
    ) -> PlaylistFile {
        insertFile(name, tags: tags, status: status, skipped: skipped, order: order, to: playlist, in: context)
    }

    /// Resolves identifiers back to filenames in order, so a sequence can be compared by name.
    private func names(_ ids: [PersistentIdentifier], in context: ModelContext) -> [String] {
        ids.compactMap { (context.model(for: $0) as? PlaylistFile)?.fileName }
    }

    /// One of each triage category plus tagged members that exercise AND/OR.
    private func seededPlaylist(in context: ModelContext) throws -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        addFile("a [beach].jpg", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("b [beach sunny].jpg", tags: ["beach", "sunny"], status: .valid, order: 1, to: playlist, in: context)
        addFile("c [sunny].jpg", tags: ["sunny"], status: .valid, order: 2, to: playlist, in: context)
        addFile("untagged.jpg", status: .untagged, order: 3, to: playlist, in: context)
        addFile("invalid.jpg", status: .invalid, order: 4, to: playlist, in: context)
        addFile("skip.txt", status: .untagged, skipped: true, order: 5, to: playlist, in: context)
        try context.save()
        return playlist
    }

    @Test func noFilterShowsNonSkippedInOrderWithCounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        let nonSkipped = ["a [beach].jpg", "b [beach sunny].jpg", "c [sunny].jpg", "untagged.jpg", "invalid.jpg"]
        #expect(names(context.displaySequence(of: playlist), in: context) == nonSkipped)
        #expect(names(context.playbackSequence(of: playlist), in: context) == nonSkipped)
        #expect(context.hasPlaybackFiles(in: playlist))

        let counts = context.serviceFilterCounts(for: playlist)
        #expect(counts.untagged == 1)
        #expect(counts.invalidTagging == 1)
        #expect(counts.skipped == 1)
    }

    @Test func eachServiceFilterDrivesTheSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState.serviceFilter = .untagged
        try context.save()
        #expect(names(context.displaySequence(of: playlist), in: context) == ["untagged.jpg"])
        #expect(names(context.playbackSequence(of: playlist), in: context) == ["untagged.jpg"])
        #expect(context.hasPlaybackFiles(in: playlist))

        playlist.filterState.serviceFilter = .invalidTagging
        try context.save()
        #expect(names(context.displaySequence(of: playlist), in: context) == ["invalid.jpg"])
        #expect(names(context.playbackSequence(of: playlist), in: context) == ["invalid.jpg"])
        #expect(context.hasPlaybackFiles(in: playlist))

        playlist.filterState.serviceFilter = .skipped
        try context.save()
        #expect(names(context.displaySequence(of: playlist), in: context) == ["skip.txt"])
        #expect(context.playbackSequence(of: playlist).isEmpty)
        #expect(!context.hasPlaybackFiles(in: playlist))
    }

    @Test func tagOrFilterMatchesAnySelectedTag() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState = FilterState(selectedTags: ["beach", "sunny"], filterMode: .or)
        try context.save()
        // OR matches any of beach/sunny: all three tagged files.
        #expect(names(context.displaySequence(of: playlist), in: context)
            == ["a [beach].jpg", "b [beach sunny].jpg", "c [sunny].jpg"])
    }

    @Test func tagAndFilterRequiresEverySelectedTag() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState = FilterState(selectedTags: ["beach", "sunny"], filterMode: .and)
        try context.save()
        // AND matches files carrying both tags: only the doubly-tagged file.
        #expect(names(context.displaySequence(of: playlist), in: context) == ["b [beach sunny].jpg"])
    }

    @Test func playlistForwardersMatchTheContextMethods() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // The thin `Playlist` members forward to the same context derivation, so they agree.
        #expect(playlist.playbackFiles.map(\.fileName)
            == context.playbackFiles(of: playlist).map(\.fileName))
        #expect(playlist.hasPlaybackFiles == context.hasPlaybackFiles(in: playlist))
        #expect(playlist.serviceFilterCounts == context.serviceFilterCounts(for: playlist))
        #expect(playlist.fileCount == context.fileCount(in: playlist))
    }

    @Test func fileCountMatchesRelationshipCount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // A `fetchCount` badge equals faulting the whole relationship — without materializing it.
        // Counts every file regardless of triage/skip state (the row badge is the raw total).
        #expect(context.fileCount(in: playlist) == 6)
        #expect(context.fileCount(in: playlist) == playlist.files.count)
    }

    @Test func unsavedInsertIsNotYetVisible() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        let before = context.displaySequence(of: playlist).count
        addFile("d [beach].jpg", tags: ["beach"], status: .valid, order: 6, to: playlist, in: context)
        // includePendingChanges: false — the pending insert is invisible until saved.
        #expect(context.displaySequence(of: playlist).count == before)

        try context.save()
        #expect(context.displaySequence(of: playlist).count == before + 1)
    }
}
