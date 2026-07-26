//
//  DeletedModelResolutionTests.swift
//  ShuTaPlaTests
//
//  Delete-crash task — the decisive experiment. Establishes, empirically, how a
//  deleted-and-saved PlaylistFile presents through the context, so the fix guards on a
//  seam that actually reflects the deletion. Every read here is metadata or a fetch —
//  none touches a persisted property — so the probe cannot trap the host.
//
//  Findings (see individual tests):
//    * model(for:) returns a NON-nil invalidated instance for a deleted-saved id — the trap risk.
//    * .modelContext, .isDeleted, registeredModel(for:) ALL still report the instance as live
//      after delete+save — none is a usable validity seam.
//    * A fetch keyed on persistentModelID is the only thing that reflects the deletion.
//    * persistentModelID stays safe to read on the invalidated instance, so a fetch-count
//      keyed on it is a valid, non-trapping isValid seam.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct DeletedModelResolutionTests {

    /// A fresh in-memory container held for the whole test body (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            PlaylistFile.self,
            ShuTaPla.Tag.self,
            AppStateModel.self,
            GlobalSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Inserts one saved file and returns (container, context, file). Container is returned so
    /// the caller keeps it alive for the whole body.
    private func insertedFile() throws -> (ModelContainer, ModelContext, PlaylistFile) {
        let container = try makeContainer()
        let context = container.mainContext
        let file = PlaylistFile(
            relativePath: "clip.mp4",
            fileName: "clip.mp4",
            taggingStatus: .valid,
            sortOrder: 0
        )
        context.insert(file)
        try context.save()
        return (container, context, file)
    }

    /// model(for:) hands back a non-nil instance for a deleted-saved id — the P1 trap risk —
    /// and none of the instance-metadata seams reflect the deletion. Only a fetch does.
    @Test func onlyAFetchReflectsDeletion() throws {
        let (container, context, file) = try insertedFile()
        _ = container
        let id = file.persistentModelID

        context.delete(file)
        try context.save()

        let resolved = context.model(for: id) as? PlaylistFile
        #expect(resolved != nil, "model(for:) returns a non-nil invalidated instance for a deleted-saved id")

        // Instance-metadata seams that DO NOT work (documented so nobody re-proposes them):
        #expect(resolved?.modelContext != nil, ".modelContext stays non-nil after delete+save")
        #expect(resolved?.isDeleted == false, ".isDeleted stays false after delete+save")
        #expect(context.registeredModel(for: id) as PlaylistFile? != nil, "registeredModel(for:) still returns it")

        // The seam that works: a fetch keyed on persistentModelID drops the deleted row.
        let byID = try context.fetch(
            FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
        )
        #expect(byID.isEmpty, "fetch by persistentModelID returns empty for the deleted-saved row")
    }

    /// persistentModelID is a safe read on the invalidated instance, and a fetch-count keyed on
    /// it is the corrected isValid seam: true for a live file, false for a deleted-saved one,
    /// and non-trapping in both cases.
    @Test func fetchCountSeamTracksValidity() throws {
        let (container, context, file) = try insertedFile()
        _ = container

        func liveInStore(_ f: PlaylistFile) -> Bool {
            guard let ctx = f.modelContext else { return false }
            let id = f.persistentModelID   // safe on an invalidated instance
            var d = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
            d.fetchLimit = 1
            return ((try? ctx.fetchCount(d)) ?? 0) > 0
        }

        #expect(liveInStore(file) == true, "a live saved file reads as valid")

        context.delete(file)
        try context.save()

        #expect(liveInStore(file) == false, "a deleted-saved file reads as invalid, without trapping")
    }

    /// The load-bearing regression guard for the P1 fix: an UNSAVED insert (temporary id) must
    /// still resolve — both through model(for:) and through the persistentModelID fetch seam —
    /// or the fix would drop pending records. Distinguishes it from the deleted-saved case.
    @Test func unsavedInsertStillResolves() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let file = PlaylistFile(
            relativePath: "fresh.mp4",
            fileName: "fresh.mp4",
            taggingStatus: .valid,
            sortOrder: 0
        )
        context.insert(file)
        // NB: no save — the record is a pending insert with a temporary persistentModelID.

        let id = file.persistentModelID

        // model(for:) resolves the pending insert (today's behaviour we must preserve).
        #expect(context.model(for: id) as? PlaylistFile != nil, "model(for:) resolves an unsaved insert")

        // Does the persistentModelID fetch seam ALSO see the pending insert?
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        let fetchCount = (try? context.fetchCount(descriptor)) ?? -1
        let fetched = (try? context.fetch(descriptor).first) != nil
        #expect(fetchCount == 1, "SEAM: fetchCount by persistentModelID sees the unsaved insert")
        #expect(fetched, "SEAM: fetch by persistentModelID resolves the unsaved insert")
    }

    /// A dirty (saved-then-modified, not-yet-saved) instance must survive resolution: an
    /// object-returning fetch keyed on persistentModelID with the DEFAULT includePendingChanges
    /// (true) must return the SAME registered instance with its unsaved edit intact — i.e. it
    /// must NOT refault. Guards the P1 resolver against dropping an in-flight metadata merge.
    @Test func dirtyInstanceSurvivesFetchResolution() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let file = PlaylistFile(
            relativePath: "clip.mp4",
            fileName: "clip.mp4",
            taggingStatus: .valid,
            sortOrder: 0
        )
        context.insert(file)
        try context.save()

        // Dirty edit, NOT saved — mirrors a mid-merge row (e.g. duration just written).
        file.duration = 42
        let id = file.persistentModelID

        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        let resolved = try #require((try? context.fetch(descriptor).first) ?? nil)

        #expect(resolved === file, "resolver returns the same registered instance")
        #expect(resolved.duration == 42, "the unsaved dirty edit survives the fetch (no refault)")
    }

    /// The P1 regression, at the real API: `AppState.file(for:)` resolves a live id and returns
    /// **nil** for a deleted-and-saved id — the outgoing-row render then finds no file and skips
    /// the persisted-property reads that trapped. Pre-fix (`model(for:)`) this returned a non-nil
    /// invalidated instance, so this assertion is the fix's red/green.
    @Test func appStateResolverDropsDeletedRow() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let file = PlaylistFile(
            relativePath: "clip.mp4",
            fileName: "clip.mp4",
            taggingStatus: .valid,
            sortOrder: 0
        )
        context.insert(file)
        try context.save()
        let id = file.persistentModelID

        let app = AppState(modelContext: context, makeVideoEngine: { try AudioPlaybackEngine() })

        #expect(app.file(for: id) === file, "resolves a live id to its instance")

        context.delete(file)
        try context.save()

        #expect(app.file(for: id) == nil, "returns nil for a deleted-saved id — no invalidated instance escapes")
    }
}
