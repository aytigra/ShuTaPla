//
//  Playlist+Filtering.swift
//  ShuTaPla
//
//  The tag rewrites that keep a playlist's filters in step with a playlist-wide tag rename or
//  removal. Every filter the playlist owns is reached — the one applied now and each saved search's
//  — and each maps all four of its lists. Pure model edits; the orchestration around them (persist,
//  cursor restore, re-center) stays on `AppState`.
//

import Foundation
import SwiftData

@MainActor
extension Playlist {
    /// The saved searches in dropdown order. `savedSearches` is unordered, as every SwiftData
    /// to-many is, so every read site — and every reorder — goes through this.
    var sortedSavedSearches: [SavedSearch] {
        savedSearches.sorted { $0.listOrder < $1.listOrder }
    }

    /// The saved search applied right now, or nil for an ad-hoc filter. Applying a search points
    /// `currentFilter` at the search's own row rather than a copy, so this *is* the question "which
    /// search is active" — there is nothing else to compare against.
    var activeSavedSearch: SavedSearch? { currentFilter?.savedSearch }

    /// Every filter this playlist owns: the applied one plus each saved search's. The applied filter
    /// is either ad-hoc (reached only through `currentFilter`) or a search's, in which case both
    /// paths name the same row — so the pair below is deduped by identity.
    private var ownedFilters: [TagFilter] {
        var filters = savedSearches.compactMap(\.filter)
        if let current = currentFilter, !filters.contains(where: { $0 === current }) {
            filters.append(current)
        }
        return filters
    }

    /// Maps every tag of every owned filter through `transform`, so a playlist-wide rename leaves no
    /// filter pointing at a tag that no longer exists on disk.
    func rewriteFilterTag(_ transform: (String) -> String) {
        for filter in ownedFilters { filter.rewriteTags(transform) }
    }

    /// Drops `tag` from every owned filter after a playlist-wide removal. A filter left with all
    /// four lists empty is deleted, taking any search saved over it — the same rule as emptying the
    /// lists by hand, since a search over no lists matches everything and names a combination that
    /// no longer exists. Returns those cascaded-away searches, so a caller still holding one can let
    /// go of it: each is read off its filter before the delete, when the relationship is still live.
    @discardableResult
    func dropFilterTag(_ tag: String) -> [SavedSearch] {
        ownedFilters.compactMap { filter in
            filter.dropTag(tag)
            guard filter.isEmpty else { return nil }
            let search = filter.savedSearch
            modelContext?.delete(filter)
            return search
        }
    }
}
