//
//  PlaybackSequences.swift
//  ShuTaPla
//
//  The one owner of file-sequence derivation and its version counter, shared by AppState (the
//  Manager center and the two overlays) and the PlaybackCoordinator (the engine-facing find-target
//  and prefetch reads). Both derive the *same* sequence for a live playlist, so memoizing it in one
//  place means a single synchronous advance derives each sequence once rather than re-fetching it
//  per read: the coordinator's `fileAfter` and the following prefetch hit one cached entry.
//
//  It wraps a bare `ModelContext` — AppState's main context in the app, a test's in-memory context
//  in the coordinator suite — so it stays as cheap to construct as a direct store fetch. The derivations
//  themselves live on `ModelContext+Sequence`; this only caches their results against `version`.
//
//  `version` is the Observation gate every memoized read touches, so bumping it re-derives the
//  surfaces that bound to a sequence. `bump()` is the single write, called once per persisted
//  mutation (from `AppState.persistAndRefresh`, the review-mode swaps, and the background-rescan tail).
//

import Foundation
import SwiftData

@MainActor
@Observable
final class PlaybackSequences {

    /// The context every sequence fetch runs against.
    let modelContext: ModelContext

    /// Bumped after every persisted mutation that can change a sequence's membership or order.
    /// Observation-tracked: the memoized reads gate on it, so a bump re-derives the bound surfaces.
    private(set) var version = 0

    /// The three derivations a playlist's center list can take — the ordinary playable sequence and
    /// the two transient Manager review modes — each memoized under its own key so they never collide
    /// (the coordinator's `.plain` read and a Manager `.skipped` read on the same live playlist stay
    /// separate).
    private enum Mode { case plain, duplicates, skipped }

    private struct Key: Hashable {
        var playlistID: PersistentIdentifier
        var mode: Mode
    }

    // The memo cache, valid only for `cachedVersion`; cleared the moment `version` moves past it.
    // `@ObservationIgnored`: caching is not a tracked write — reading `version` is the gate.
    @ObservationIgnored private var cache: [Key: [PersistentIdentifier]] = [:]
    @ObservationIgnored private var cachedVersion = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Marks every memoized sequence stale, so the next read re-derives from the saved store.
    func bump() { version &+= 1 }

    /// The playlist's ordered playable sequence — the file list, the overlays, and playback share it.
    func sequence(of playlist: Playlist) -> [PersistentIdentifier] {
        memoized(playlist, .plain) { modelContext.sequence(of: $0) }
    }

    /// The find-duplicates review sequence (files whose fingerprint recurs, grouped by fingerprint).
    func duplicateSequence(of playlist: Playlist) -> [PersistentIdentifier] {
        memoized(playlist, .duplicates) { modelContext.duplicateSequence(of: $0) }
    }

    /// The skipped-review list (wrong-type/unplayable files, in `sortOrder`).
    func skippedSequence(of playlist: Playlist) -> [PersistentIdentifier] {
        memoized(playlist, .skipped) { modelContext.skippedSequence(of: $0) }
    }

    /// Returns `compute(playlist)` memoized under `(playlist, mode)` for the current `version`,
    /// re-deriving only when a `bump()` moved the version past the cache. Reading `version` here is
    /// the Observation dependency that drives re-derivation; every consumer in a version reuses the
    /// same entry per playlist, so a single advance derives each sequence once.
    private func memoized(
        _ playlist: Playlist, _ mode: Mode,
        compute: (Playlist) -> [PersistentIdentifier]
    ) -> [PersistentIdentifier] {
        _ = version
        if cachedVersion != version {
            cache.removeAll(keepingCapacity: true)
            cachedVersion = version
        }
        let key = Key(playlistID: playlist.persistentModelID, mode: mode)
        if let hit = cache[key] { return hit }
        let ids = compute(playlist)
        cache[key] = ids
        return ids
    }
}
