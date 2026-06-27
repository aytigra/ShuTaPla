//
//  SequenceStoreTests.swift
//  ShuTaPlaTests
//
//  Task 17 (Stage B) — the store-side derivation on `ModelContext` returns the same order,
//  membership, and counts as the in-memory `Playlist` computed properties, across no filter,
//  each service filter, and tag AND/OR. Because the fetches use `includePendingChanges: false`,
//  every scenario saves before deriving; a separate case pins that an unsaved insert is not
//  yet visible.
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
        let file = PlaylistFile(
            relativePath: name, fileName: name,
            taggingStatus: status, isSkipped: skipped, sortOrder: order
        )
        file.playlist = playlist
        context.insert(file)
        file.tags = context.tags(named: tags)
        return file
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

    /// Asserts the store-side derivation matches the in-memory computed properties for the
    /// playlist's current filter.
    private func expectParity(_ playlist: Playlist, in context: ModelContext) {
        #expect(names(context.displaySequence(of: playlist), in: context)
            == playlist.displaySequence.map(\.fileName))
        #expect(names(context.playbackSequence(of: playlist), in: context)
            == playlist.playbackSequence.map(\.fileName))
        #expect(context.hasPlaybackFiles(in: playlist) == playlist.hasPlaybackFiles)

        let stored = context.serviceFilterCounts(for: playlist)
        let walked = playlist.serviceFilterCounts
        #expect(stored.untagged == walked.untagged)
        #expect(stored.invalidTagging == walked.invalidTagging)
        #expect(stored.skipped == walked.skipped)
    }

    @Test func parityWithNoFilter() throws {
        let container = try makeContainer()
        let playlist = try seededPlaylist(in: container.mainContext)
        expectParity(playlist, in: container.mainContext)
    }

    @Test func parityUnderEachServiceFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        for service in [ServiceFilter.untagged, .invalidTagging, .skipped] {
            playlist.filterState.serviceFilter = service
            try context.save()
            expectParity(playlist, in: context)
        }
    }

    @Test func parityUnderTagOrFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState = FilterState(selectedTags: ["beach", "sunny"], filterMode: .or)
        try context.save()
        // OR matches any of beach/sunny: all three tagged files.
        #expect(names(context.displaySequence(of: playlist), in: context)
            == ["a [beach].jpg", "b [beach sunny].jpg", "c [sunny].jpg"])
        expectParity(playlist, in: context)
    }

    @Test func parityUnderTagAndFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState = FilterState(selectedTags: ["beach", "sunny"], filterMode: .and)
        try context.save()
        // AND matches files carrying both tags: only the doubly-tagged file.
        #expect(names(context.displaySequence(of: playlist), in: context) == ["b [beach sunny].jpg"])
        expectParity(playlist, in: context)
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
