//
//  PersistentModel+Save.swift
//  ShuTaPla
//
//  Store-lifecycle helpers for the derived-metadata caches: a best-effort save on any model's own
//  context, and a `PlaylistFile` check for whether its row still exists after a deletion.
//

import Foundation
import SwiftData

extension PersistentModel {
    /// Assigns `value` only when it differs from what's there. SwiftData dirties a record — and
    /// re-fires its per-keypath Observation — on an *equal* write just as on a real one, so a
    /// derived-fact producer that re-states what a record already holds costs a re-render and a save
    /// for nothing. The idempotent sinks (the metadata merge, the HDR records) write through this,
    /// which is what keeps a gallery scroll over already-cached files from dirtying and saving once
    /// per cell.
    ///
    /// `nonisolated` because a `@Model` type doesn't take the module's MainActor default, so its own
    /// extension members are nonisolated contexts — `PlaylistFile.merge` is one, and can call only a
    /// nonisolated sink, though like every caller here it runs on the main actor. `trySave` below is
    /// MainActor: this protocol extension does take the default.
    nonisolated func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    /// Flushes this model's context to the store when it has something to flush, ignoring a failure.
    /// The metadata producers (the gallery thumbnail merge, the list-mode extract) persist their
    /// derived facts this way so an unsaved dirty edit isn't refaulted back to stored values by the
    /// next `includePendingChanges = false` object fetch. A failed save costs nothing more than
    /// re-deriving the fact on the next display, so — unlike a user mutation, which routes through
    /// `AppState.persistAndRefresh` for its rollback and error surfacing — it needn't be surfaced.
    ///
    /// The `hasChanges` gate is what lets those producers call this unconditionally: a sink that
    /// re-states facts a record already holds leaves the context clean, so the save is skipped here
    /// rather than at each call site.
    func trySave() {
        guard modelContext?.hasChanges == true else { return }
        try? modelContext?.save()
    }
}

extension PlaylistFile {
    /// Whether this file's row still exists in the store. A deleted-and-saved instance keeps a
    /// live-looking `modelContext` and registration and reports `isDeleted == false`, yet reading any
    /// persisted property on it traps (`backing data could no longer be found`); only a store fetch
    /// reflects the deletion. Producers that write the model after an `await` — a thumbnail/metadata
    /// merge, an HDR record, a timeline-position persist — guard on this so a file trashed mid-decode
    /// is skipped instead of trapping. `persistentModelID` stays a safe read on the invalidated
    /// instance, and the default `includePendingChanges` keeps an unsaved insert present (its temporary
    /// id still matches) without refaulting a dirty row.
    var existsInStore: Bool {
        guard let context = modelContext else { return false }
        let id = persistentModelID
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
