//
//  PlaylistPlaybackTests.swift
//  ShuTaPlaTests
//
//  The effective-filter rule, derived store-side on `ModelContext` and exercised through the
//  model-resolving `sequenceFiles` / `sequenceNotEmpty`. The triage filter, when set, overrides
//  the tag filter; skipped (wrong-type) files are excluded from the sequence entirely and reached
//  only through `skippedSequence`, the review list. The derivations fetch with
//  `includePendingChanges: false`, so each scenario saves before deriving.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct PlaylistPlaybackTests {

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

    /// A playlist seeded with a tagged file, an untagged file, an invalid-tagging file, and a
    /// skipped file — one of each triage category plus a normal tagged member — saved so the
    /// store-side derivations can see it.
    private func seededPlaylist(in context: ModelContext) throws -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("tagged [beach].mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("untagged.mp4", status: .untagged, order: 1, to: playlist, in: context)
        addFile("invalid [ab].mp4", status: .invalid, order: 2, to: playlist, in: context)
        addFile("skip.jpg", status: .untagged, skipped: true, order: 3, to: playlist, in: context)
        try context.save()
        return playlist
    }

    @Test func noFilterShowsPlayableExcludesSkipped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        #expect(context.sequenceFiles(of: playlist).map(\.fileName) == ["tagged [beach].mp4", "untagged.mp4", "invalid [ab].mp4"])
        #expect(context.sequenceNotEmpty(in: playlist))
    }

    @Test func tagFilterNarrowsTheSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and)
        try context.save()

        #expect(context.sequenceFiles(of: playlist).map(\.fileName) == ["tagged [beach].mp4"])
        #expect(context.sequenceNotEmpty(in: playlist))
    }

    @Test func untaggedServiceFilterOverridesTagFilter() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        // A tag filter is set too, to prove the triage filter overrides it.
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and, serviceFilter: .untagged)
        try context.save()

        #expect(context.sequenceFiles(of: playlist).map(\.fileName) == ["untagged.mp4"])
        #expect(context.sequenceNotEmpty(in: playlist))   // untagged files are playable — loop them to fix
    }

    @Test func invalidTaggingServiceFilterDrivesTheSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        playlist.filterState.serviceFilter = .invalidTagging
        try context.save()

        #expect(context.sequenceFiles(of: playlist).map(\.fileName) == ["invalid [ab].mp4"])
        #expect(context.sequenceNotEmpty(in: playlist))
    }

    @Test func skippedFilesAreExcludedFromTheSequenceAndListedForReview() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // A wrong-type file never enters the sequence (it can't be played); it surfaces only in the
        // skipped-review list, for delete / show-in-folder / rename.
        #expect(!context.sequenceFiles(of: playlist).map(\.fileName).contains("skip.jpg"))
        let skipped = context.skippedSequence(of: playlist).compactMap { context.model(for: $0) as? PlaylistFile }
        #expect(skipped.map(\.fileName) == ["skip.jpg"])
    }
}
