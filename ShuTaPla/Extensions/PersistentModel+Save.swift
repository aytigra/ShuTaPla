//
//  PersistentModel+Save.swift
//  ShuTaPla
//
//  A best-effort save on any model's own context, for the derived-metadata caches.
//

import SwiftData

extension PersistentModel {
    /// Flushes this model's context to the store, ignoring a failure. The metadata producers (the
    /// gallery thumbnail merge, the list-mode extract) persist their derived facts this way so an
    /// unsaved dirty edit isn't refaulted back to stored values by the next
    /// `includePendingChanges = false` object fetch. A failed save costs nothing more than
    /// re-deriving the fact on the next display, so — unlike a user mutation, which routes through
    /// `AppState.persistAndRefresh` for its rollback and error surfacing — it needn't be surfaced.
    func trySave() {
        try? modelContext?.save()
    }
}
