//
//  Playlist+Filtering.swift
//  ShuTaPla
//
//  The playlist's saved-search memory and the tag rewrites that keep filters in step with a
//  playlist-wide tag rename or removal. Pure model edits over `filterState` and `savedSearches`;
//  the orchestration around them (persist, cursor restore, re-center) stays on `AppState`.
//

import Foundation
import SwiftData

@MainActor
extension Playlist {
    /// Remembers the current tag filter as a saved search (most-recent first, unique by tag set +
    /// operator). A no-op when the filter is empty.
    func saveCurrentSearch() {
        guard filterState.isNotEmpty else { return }
        promoteSearch(SavedSearch(tags: filterState.selectedTags, mode: filterState.filterMode))
    }

    /// Re-applies a saved search — sets it as the active filter and moves it to the top of the
    /// recents. The caller settles the cursor (`filterChanged`).
    func applySavedSearch(_ search: SavedSearch) {
        filterState.serviceFilter = nil
        filterState.selectedTags = search.tags
        filterState.filterMode = search.mode
        promoteSearch(search)
    }

    /// Removes a saved search from the recents.
    func removeSavedSearch(_ search: SavedSearch) {
        savedSearches.removeAll { $0.matches(search) }
    }

    /// Moves the matching saved search to the top of the recents, or inserts `search` when none
    /// matches. An existing match is kept as-is — preserving its captured `resumeSortOrder` — so
    /// re-saving a filter that is already saved never discards its remembered position.
    private func promoteSearch(_ search: SavedSearch) {
        let existing = savedSearches.first { $0.matches(search) }
        var searches = savedSearches.filter { !$0.matches(search) }
        searches.insert(existing ?? search, at: 0)
        savedSearches = searches
    }

    /// Maps every tag in the active tag filter and the saved searches through `transform`, keeping
    /// filter state in step with a playlist-wide tag rename so the filter doesn't keep pointing at
    /// a tag that no longer exists on disk.
    func rewriteFilterTag(_ transform: (String) -> String) {
        filterState.selectedTags = TagParser.dedupe(filterState.selectedTags.map(transform))
        savedSearches = savedSearches.map {
            var search = $0
            search.tags = TagParser.dedupe($0.tags.map(transform))
            return search
        }
    }

    /// Drops `tag` from the active tag filter and the saved searches after a playlist-wide removal.
    /// A saved search that referenced the tag is discarded outright when removing it would leave one
    /// tag or none — a resume position belongs to a specific tag combination, so it goes with the
    /// search rather than orphaning onto a narrower one. A search left with two or more tags
    /// survives, rewritten to the remainder; one that never carried the tag is untouched.
    func dropFilterTag(_ tag: String) {
        filterState.selectedTags.removeAll { TagParser.sameTag($0, tag) }
        savedSearches = savedSearches.compactMap { search in
            let remaining = search.tags.filter { !TagParser.sameTag($0, tag) }
            guard remaining.count == search.tags.count || remaining.count > 1 else { return nil }
            var updated = search
            updated.tags = remaining
            return updated
        }
    }
}
