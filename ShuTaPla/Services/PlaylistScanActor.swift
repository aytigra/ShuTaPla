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

@ModelActor
actor PlaylistScanActor {

    /// Reconciles the playlist with app id `playlistID` against `current` (every file now on disk,
    /// each with its derived tags), saves, and sweeps tags orphaned by the reassignment. Returns
    /// what changed for the main actor to finish applying. A playlist not yet in the store, or a
    /// no-op scan (nothing diverged), neither saves nor sweeps — there are no new orphans without
    /// a tag reassignment.
    func reconcile(_ current: [ScannedFile], playlistID: UUID) -> ScanReconcileResult {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
        descriptor.fetchLimit = 1
        guard let playlist = try? modelContext.fetch(descriptor).first else { return .unchanged }
        let result = modelContext.reconcile(current, into: playlist)
        guard result.changed else { return result }
        try? modelContext.save()
        modelContext.cleanupOrphanTags()
        return result
    }
}
