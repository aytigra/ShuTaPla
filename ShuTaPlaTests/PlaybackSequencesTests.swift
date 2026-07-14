//
//  PlaybackSequencesTests.swift
//  ShuTaPlaTests
//
//  The shared sequence provider's memoization contract: a derivation is cached until `bump()`, so
//  every consumer in a version (the Manager center, the overlays, the coordinator's find-target and
//  prefetch reads) reuses one entry rather than re-fetching — and a persisted mutation is seen only
//  once its `bump()` invalidates the cache. The three modes cache under distinct keys.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct PlaybackSequencesTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func seededPlaylist(in context: ModelContext) throws -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        insertFile("0.jpg", order: 0, to: playlist, in: context)
        insertFile("1.jpg", order: 1, to: playlist, in: context)
        try context.save()
        return playlist
    }

    @Test func bumpAdvancesTheVersion() throws {
        let container = try makeContainer()
        let sequences = PlaybackSequences(modelContext: container.mainContext)
        let before = sequences.version
        sequences.bump()
        #expect(sequences.version == before + 1)
    }

    /// The memo is real: a file saved without a `bump()` is *not* reflected — the cached sequence
    /// stands — until `bump()` invalidates it. This is the double-fetch elimination that closes
    /// finding N (two reads in one version derive once) and the reason every mutation path bumps.
    @Test func sequenceIsMemoizedUntilBumped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        let sequences = PlaybackSequences(modelContext: context)

        let first = sequences.sequence(of: playlist)
        #expect(first.count == 2)

        // A third file lands in the store, saved but un-bumped: the cached sequence still stands.
        insertFile("2.jpg", order: 2, to: playlist, in: context)
        try context.save()
        #expect(sequences.sequence(of: playlist) == first)

        // The bump every mutation path performs invalidates the cache; the next read re-derives.
        sequences.bump()
        #expect(sequences.sequence(of: playlist).count == 3)
    }

    /// The three derivations cache under distinct keys, so asking for one never returns another's
    /// result: the plain sequence excludes the skipped file that `skippedSequence` lists.
    @Test func modesAreMemoizedIndependently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        insertFile("0.jpg", order: 0, to: playlist, in: context)
        insertFile("skip.txt", skipped: true, order: 1, to: playlist, in: context)
        try context.save()

        let sequences = PlaybackSequences(modelContext: context)
        let plain = sequences.sequence(of: playlist).compactMap { context.model(for: $0) as? PlaylistFile }
        let skipped = sequences.skippedSequence(of: playlist).compactMap { context.model(for: $0) as? PlaylistFile }

        #expect(plain.map(\.fileName) == ["0.jpg"])
        #expect(skipped.map(\.fileName) == ["skip.txt"])
        // A re-read of each within the same version stays consistent (both served from the cache).
        #expect(sequences.sequence(of: playlist).count == 1)
        #expect(sequences.skippedSequence(of: playlist).count == 1)
    }
}
