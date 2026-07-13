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
        addFile("invalid [ab].jpg", status: .invalid, order: 4, to: playlist, in: context)
        addFile("skip.txt", status: .untagged, skipped: true, order: 5, to: playlist, in: context)
        try context.save()
        return playlist
    }

    @Test func noFilterShowsNonSkippedInOrderWithCounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        let nonSkipped = ["a [beach].jpg", "b [beach sunny].jpg", "c [sunny].jpg", "untagged.jpg", "invalid [ab].jpg"]
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
        #expect(names(context.displaySequence(of: playlist), in: context) == ["invalid [ab].jpg"])
        #expect(names(context.playbackSequence(of: playlist), in: context) == ["invalid [ab].jpg"])
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

    @Test func tagNotAnyFilterExcludesEverySelectedTag() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState = FilterState(selectedTags: ["beach", "sunny"], filterMode: .notAny)
        try context.save()
        // Complement of OR: files carrying neither tag — the two untagged files are included
        // (honest "has none of the selected tags"), the three tagged ones excluded.
        #expect(names(context.displaySequence(of: playlist), in: context)
            == ["untagged.jpg", "invalid [ab].jpg"])
    }

    @Test func tagNotAllFilterExcludesFilesCarryingEverySelectedTag() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.filterState = FilterState(selectedTags: ["beach", "sunny"], filterMode: .notAll)
        try context.save()
        // Complement of AND: only the doubly-tagged file has both, so every other non-skipped file
        // (missing at least one — including the untagged ones) is included.
        #expect(names(context.displaySequence(of: playlist), in: context)
            == ["a [beach].jpg", "c [sunny].jpg", "untagged.jpg", "invalid [ab].jpg"])
    }

    @Test func singleSelectedTagMakesNotAllAndNotAnyCoincide() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // With one selected tag, "missing all of it" == "has none of it": both exclude a and b.
        let expected = ["c [sunny].jpg", "untagged.jpg", "invalid [ab].jpg"]
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .notAll)
        try context.save()
        #expect(names(context.displaySequence(of: playlist), in: context) == expected)

        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .notAny)
        try context.save()
        #expect(names(context.displaySequence(of: playlist), in: context) == expected)
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

    @Test func playbackResumeTargetResolvesAtOrAfterElseWraps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // Playback order (skipped excluded): a(0) b(1) c(2) untagged(3) invalid(4).
        #expect(context.playbackResumeTarget(of: playlist, atOrAfter: 2)?.fileName == "c [sunny].jpg")
        #expect(context.playbackResumeTarget(of: playlist, atOrAfter: 3)?.fileName == "untagged.jpg")
        // The skipped file at order 5 is not a playback file, so nothing qualifies at/after 5 → wrap.
        #expect(context.playbackResumeTarget(of: playlist, atOrAfter: 5)?.fileName == "a [beach].jpg")
        // No lower bound resolves the first playback file.
        #expect(context.playbackResumeTarget(of: playlist, atOrAfter: .min)?.fileName == "a [beach].jpg")

        // Under the skipped service filter playback is empty — no resume target at all.
        playlist.filterState.serviceFilter = .skipped
        try context.save()
        #expect(context.playbackResumeTarget(of: playlist, atOrAfter: 0) == nil)
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

    @Test func filesAtRelativePathsResolvesOnlyThatSubset() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // The live cloud feed folds just the paths a metadata delta reports — never the whole set.
        let hits = context.files(in: playlist, atRelativePaths: ["a [beach].jpg", "untagged.jpg"])
        #expect(Set(hits.map(\.relativePath)) == ["a [beach].jpg", "untagged.jpg"])

        // An unknown path contributes nothing; an empty request fetches nothing at all.
        #expect(context.files(in: playlist, atRelativePaths: ["ghost.jpg"]).isEmpty)
        #expect(context.files(in: playlist, atRelativePaths: []).isEmpty)
    }

    @Test func filesAtRelativePathsIsScopedToThePlaylist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let p1 = try seededPlaylist(in: context)
        let p2 = Playlist(name: "Q", folderBookmark: Data(), folderPath: "/q", mediaType: .image)
        context.insert(p2)
        insertFile("a [beach].jpg", status: .valid, order: 0, to: p2, in: context)  // same path, other playlist
        try context.save()

        // The `persistentModelID` scope keeps the collision in `p1` out — only `p2`'s file returns.
        let hits = context.files(in: p2, atRelativePaths: ["a [beach].jpg"])
        #expect(hits.count == 1)
        #expect(hits.first?.playlist?.persistentModelID == p2.persistentModelID)
        #expect(context.files(in: p1, atRelativePaths: ["a [beach].jpg"]).first?.playlist?.persistentModelID
            == p1.persistentModelID)
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
