//
//  PlaylistScanActor.swift
//  ShuTaPla
//
//  The background half of the Update path. A `@ModelActor` owns its own `ModelContext` on the
//  shared `ModelContainer`, so reconciling a playlist's files against a fresh folder listing —
//  the O(N) derive / diff / write / orphan-sweep — runs off the main actor, which writes and
//  saves everything derived (files, tags, `tagFrequency`). The main actor is left with only the
//  O(1) work: dropping any UI reference to a pruned file and bumping the version so the store-side
//  file lists re-fetch.
//
//  Models are not `Sendable` across contexts, so the boundary is value types only: the
//  playlist's app-level `UUID` in, a `ScanReconcileResult` out. The actor resolves the playlist
//  by that id with a store-side fetch — robust where a cross-context `PersistentIdentifier` is
//  not (a still-temporary one resolves to a backing-less phantom that traps on first access).
//  The main context sees the committed writes on its next store-side fetch.
//

import Foundation
import SwiftData
import Synchronization

@ModelActor
actor PlaylistScanActor {

    /// Test-only seam: invoked on this actor in the post-diff/pre-save window, the only place a
    /// test can land a cancellation between deciding a reconcile changed something and committing
    /// it. `nil` (and never set) in production, where the `withLock` read is a no-op. Held in a
    /// `Mutex` so a test can install it synchronously without hopping onto the actor.
    nonisolated let preSaveHook = Mutex<(@Sendable () -> Void)?>(nil)

    /// Test-only seam: replaces the real `modelContext.save()` so a test can force the commit to
    /// throw and assert the failure surfaces. `nil` (and never set) in production, where the real
    /// save runs. Held in a `Mutex` for the same reason as `preSaveHook` — synchronous install
    /// from a test, no actor hop.
    nonisolated let saveOverride = Mutex<(@Sendable () throws -> Void)?>(nil)

    /// Reconciles the playlist with app id `playlistID` against `current` (every file now on disk,
    /// each with its derived tags), saves, and sweeps tags orphaned by the reassignment. Returns
    /// what changed for the main actor to finish applying. A playlist not yet in the store, or a
    /// no-op scan (nothing diverged), neither saves nor sweeps — there are no new orphans without
    /// a tag reassignment.
    ///
    /// The commit decision is made *before* the save: a reconcile either commits and is fully
    /// applied on the main actor, or it does not commit at all. The method runs within the caller's
    /// task, so a cancellation observed here is the `update` task's — if it is cancelled before the
    /// save (e.g. the playlist was re-selected or deleted), the work is rolled back and reported as
    /// `.unchanged`, never committed without its main-actor tail running. A save that throws is
    /// likewise rolled back and reported with `changed == false` and a `saveErrorMessage`, so a
    /// failed save is never treated as a commit; the main actor surfaces the message.
    func reconcile(_ current: [ScannedFile], playlistID: UUID) -> ScanReconcileResult {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
        descriptor.fetchLimit = 1
        guard let playlist = try? modelContext.fetch(descriptor).first else { return .unchanged }
        let result = modelContext.reconcile(current, into: playlist)
        guard result.changed else { return result }
        preSaveHook.withLock { $0 }?()
        guard !Task.isCancelled else {
            modelContext.rollback()
            return .unchanged
        }
        let override = saveOverride.withLock { $0 }
        do {
            try (override ?? modelContext.save)()
        } catch {
            // A failed save commits nothing: roll back the uncommitted edit so a later reconcile's
            // save can't silently flush it, and hand the failure back for the main actor to surface
            // (no `cleanupOrphanTags`, no main-side apply, since `changed` is now false).
            modelContext.rollback()
            return ScanReconcileResult(removedFileIDs: [], changed: false,
                                       saveErrorMessage: error.localizedDescription)
        }
        modelContext.cleanupOrphanTags()
        return result
    }
}
