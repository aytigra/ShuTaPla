//
//  SequenceStoreTests.swift
//  ShuTaPlaTests
//
//  Task 17 (Stage B) — the store-side derivation on `ModelContext`: the ordered sequence
//  identifiers, the skipped-review list, the triage counts and the path-scoped lookups, under no
//  filter and under each service filter. The fetches use `includePendingChanges: false`, so every
//  scenario saves before deriving; a separate case pins that an unsaved insert is not yet visible.
//  The tag filter's own rules live in `TagFilterPredicateTests`, over a fixture built to
//  discriminate them; what belongs here is only the precedence between the two filter kinds.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct SequenceStoreTests {

    /// Holds the container for the whole body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
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

    /// One of each triage category, plus tagged members a tag filter can select against.
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
        #expect(names(context.sequence(of: playlist), in: context) == nonSkipped)
        #expect(context.sequenceNotEmpty(in: playlist))

        let counts = context.serviceFilterCounts(for: playlist)
        #expect(counts.untagged == 1)
        #expect(counts.invalidTagging == 1)
        #expect(counts.skipped == 1)
    }

    @Test func eachServiceFilterDrivesTheSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        playlist.serviceFilter = .untagged
        try context.save()
        #expect(names(context.sequence(of: playlist), in: context) == ["untagged.jpg"])
        #expect(context.sequenceNotEmpty(in: playlist))

        playlist.serviceFilter = .invalidTagging
        try context.save()
        #expect(names(context.sequence(of: playlist), in: context) == ["invalid [ab].jpg"])
        #expect(context.sequenceNotEmpty(in: playlist))
    }

    @Test func skippedSequenceListsSkippedFilesAbsentFromTheSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // The skipped file is the review tool's only surface — it never appears in the ordinary
        // sequence (no filter shows it), so a wrong-type file is listed for triage but not played.
        #expect(names(context.skippedSequence(of: playlist), in: context) == ["skip.txt"])
        #expect(!names(context.sequence(of: playlist), in: context).contains("skip.txt"))
    }

    @Test func theServiceFilterWinsOverASetTagFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // The two are storable together, and the store resolves them by precedence: the tag filter
        // underneath survives the detour and comes back when the triage filter is cleared.
        applyTagFilter(to: playlist, in: context, mustHaveAll: ["beach"])
        playlist.serviceFilter = .untagged
        try context.save()
        #expect(names(context.sequence(of: playlist), in: context) == ["untagged.jpg"])

        playlist.serviceFilter = nil
        try context.save()
        #expect(names(context.sequence(of: playlist), in: context)
            == ["a [beach].jpg", "b [beach sunny].jpg"])
    }

    @Test func playlistForwardersMatchTheContextMethods() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // The thin `Playlist` members forward to the same context derivation, so they agree.
        #expect(playlist.sequenceFiles.map(\.fileName)
            == context.sequenceFiles(of: playlist).map(\.fileName))
        #expect(playlist.sequenceNotEmpty == context.sequenceNotEmpty(in: playlist))
        #expect(playlist.serviceFilterCounts == context.serviceFilterCounts(for: playlist))
        #expect(playlist.fileCount == context.fileCount(in: playlist))
    }

    @Test func resumeTargetResolvesAtOrAfterElseWraps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // Sequence order (skipped excluded): a(0) b(1) c(2) untagged(3) invalid(4).
        #expect(context.resumeTarget(of: playlist, atOrAfter: 2)?.fileName == "c [sunny].jpg")
        #expect(context.resumeTarget(of: playlist, atOrAfter: 3)?.fileName == "untagged.jpg")
        // The skipped file at order 5 is not in the sequence, so nothing qualifies at/after 5 → wrap.
        #expect(context.resumeTarget(of: playlist, atOrAfter: 5)?.fileName == "a [beach].jpg")
        // No lower bound resolves the first sequence file.
        #expect(context.resumeTarget(of: playlist, atOrAfter: .min)?.fileName == "a [beach].jpg")
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

        let before = context.sequence(of: playlist).count
        addFile("d [beach].jpg", tags: ["beach"], status: .valid, order: 6, to: playlist, in: context)
        // includePendingChanges: false — the pending insert is invisible until saved.
        #expect(context.sequence(of: playlist).count == before)

        try context.save()
        #expect(context.sequence(of: playlist).count == before + 1)
    }
}
