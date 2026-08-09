//
//  AppState+Filtering.swift
//  ShuTaPla
//
//  The filter and saved-search orchestration: each wrapper edits the *given* playlist's persisted
//  filter rows and then settles the surfaces through `filterChanged` — restore the incoming
//  filter's remembered cursor, follow a live channel to it, and re-center the managed selection.
//
//  Two lifecycles live here, one per section. `apply(_:to:)` is the only place `currentFilter` is
//  assigned, and so the only place a *replaced* row is disposed of; `toggleFilterTag(_:in:on:)` is
//  the only place a row is created or emptied out of existence. Everything a saved search does to
//  its filter rides the cascade the two models declare, so no method deletes both ends by hand.
//

import Foundation
import SwiftData

extension AppState {

    /// Toggles a triage filter on `playlist`, leaving any tag filter set underneath untouched so it
    /// comes back when the triage filter is cleared. The reverse direction *does* write — setting a
    /// tag filter clears the triage one — because the strip hides a tag filter while triage is on,
    /// and without the side effect a tag edit would look like it did nothing.
    func toggleServiceFilter(_ filter: ServiceFilter, on playlist: Playlist) {
        playlist.serviceFilter = playlist.serviceFilter == filter ? nil : filter
        filterChanged(on: playlist)
    }

    /// Replaces `playlist`'s tag filter with a single must-have-all tag — the `PlaylistTagsView`
    /// row tap. A fresh ad-hoc filter rather than an edit in place, so a saved search the playlist
    /// happened to be applying keeps its own lists.
    func setTagFilter(to tag: String, on playlist: Playlist) {
        let filter = TagFilter()
        filter.mustHaveAll = [tag]
        playlist.modelContext?.insert(filter)
        apply(filter, to: playlist)
        playlist.serviceFilter = nil
        filterChanged(on: playlist)
    }

    /// Adds `tag` to one field of `playlist`'s filter, or removes it when the field already carries
    /// it — the strip's token field, and the one path a filter row is created or destroyed by.
    ///
    /// The row follows the tokens: it is inserted on the first one added to an unfiltered playlist
    /// and deleted when the last one leaves, so an all-empty `TagFilter` never exists. That delete
    /// cascades to any search saved over it — a name for a combination that no longer exists, and a
    /// search over no lists would match everything. Every edit also clears the triage filter, which
    /// otherwise hides the very filter being edited.
    func toggleFilterTag(_ tag: String, in field: TagFilterField, on playlist: Playlist) {
        let filter = playlist.currentFilter ?? TagFilter()
        let tags = filter[field]
        filter[field] = tags.contains { TagParser.sameTag($0, tag) }
            ? tags.filter { !TagParser.sameTag($0, tag) }
            : tags + [tag]

        if filter.isEmpty {
            // Only a removal can empty the lists, and a removal only reaches a row already applied,
            // so this is never the fresh row above — which is why it is safe to delete unconditionally.
            playlist.modelContext?.delete(filter)
        } else if playlist.currentFilter !== filter {
            playlist.modelContext?.insert(filter)
            playlist.currentFilter = filter
        }
        playlist.serviceFilter = nil
        filterChanged(on: playlist)
    }

    /// Applies a saved search, pointing `currentFilter` at the search's *own* filter row rather than
    /// a copy — so editing the lists afterwards edits the search, with no commit step.
    func applySavedSearch(_ search: SavedSearch, on playlist: Playlist) {
        apply(search.filter, to: playlist)
        playlist.serviceFilter = nil
        filterChanged(on: playlist)
    }

    /// Leaves `playlist` unfiltered, discarding an ad-hoc filter and keeping a saved one.
    func clearTagFilter(on playlist: Playlist) {
        apply(nil, to: playlist)
        filterChanged(on: playlist)
    }

    // MARK: - Saved searches

    /// Names the applied filter, saving the search over that very row so later edits to the lists
    /// edit the search — there is no commit step. A combination another search already covers is
    /// refused through `errorNotice` rather than creating a second entry for it; the comparison is
    /// per-field, normalized and order-insensitive, and runs once per press rather than in a `body`.
    func saveCurrentSearch(named name: String, on playlist: Playlist) {
        guard let filter = playlist.currentFilter else { return }
        let combination = filter.normalizedFields
        if let existing = playlist.savedSearches.first(where: { $0.filter?.normalizedFields == combination }) {
            errorNotice = ErrorNotice(
                title: "Already saved",
                message: "The search “\(existing.name)” already covers this combination."
            )
            return
        }

        let search = SavedSearch(name: displayName(name), listOrder: playlist.savedSearches.count)
        playlist.modelContext?.insert(search)
        search.playlist = playlist
        search.filter = filter
        persistAndRefresh()
    }

    /// Renames a saved search. Names need not be unique — the filter's tags, shown under the name,
    /// are what tell two searches apart — so the only correction is a blank one.
    func renameSavedSearch(_ search: SavedSearch, to name: String) {
        search.name = displayName(name)
        persistAndRefresh()
    }

    /// Deletes a saved search, taking its filter with it through the cascade — so deleting the
    /// active one leaves the playlist unfiltered rather than keeping its lists as an ad-hoc filter.
    /// The survivors are renumbered so `listOrder` stays contiguous and the next save, which
    /// appends at `count`, cannot collide with a row that outlived a gap.
    func deleteSavedSearch(_ search: SavedSearch, on playlist: Playlist) {
        let wasActive = playlist.activeSavedSearch === search
        let remaining = playlist.sortedSavedSearches.filter { $0 !== search }
        playlist.modelContext?.delete(search)
        renumber(remaining)

        if wasActive { filterChanged(on: playlist) } else { persistAndRefresh() }
    }

    /// Moves a saved search one place in the dropdown — the row's up/down buttons, `offset` being
    /// -1 or +1. A move off either end is a no-op. Applying a search never reorders the list, so
    /// this is the only thing that rewrites `listOrder`.
    func moveSavedSearch(_ search: SavedSearch, by offset: Int, on playlist: Playlist) {
        var ordered = playlist.sortedSavedSearches
        guard let index = ordered.firstIndex(where: { $0 === search }),
              ordered.indices.contains(index + offset) else { return }
        ordered.swapAt(index, index + offset)
        renumber(ordered)
        persistAndRefresh()
    }

    /// Writes each search's position back onto `listOrder`.
    private func renumber(_ ordered: [SavedSearch]) {
        for (index, search) in ordered.enumerated() { search.listOrder = index }
    }

    /// A user-entered name trimmed for storage, with the placeholder standing in for a blank one.
    private func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SavedSearch.defaultName : trimmed
    }

    /// Points `playlist` at `filter` — the one place `currentFilter` is assigned, and so the one
    /// place the outgoing row is disposed of. An ad-hoc filter becomes unreachable the moment it
    /// stops being applied, so it is deleted; a filter a search was saved over stays reachable
    /// through the search and is left alone.
    private func apply(_ filter: TagFilter?, to playlist: Playlist) {
        let outgoing = playlist.currentFilter
        playlist.currentFilter = filter
        if let outgoing, outgoing !== filter, outgoing.savedSearch == nil {
            playlist.modelContext?.delete(outgoing)
        }
    }

    /// Settles a playlist into the incoming filter after its filter rows were edited. The new
    /// filter is persisted first so the store-side sequence reflects it, then the incoming filter's
    /// remembered slot is restored onto `currentFileID`: a live channel follows to that file (audio
    /// switches tracks now, a suppressed visual pre-loads), while a filter with no stored position
    /// falls back to the reconcile (advance only if the current file left the set). The managed
    /// playlist re-centers its selection on the resulting cursor.
    private func filterChanged(on playlist: Playlist) {
        if managedPlaylist === playlist { exitReviewModes() }   // filtering exits any review mode
        persistAndRefresh()   // the new filter must be in the store before the sequence/slot are read

        if let target = restoreTarget(for: playlist) {
            playlist.currentFileID = target.id
            // A live channel reloads whenever its engine isn't already showing the target — catching
            // the channel a prior empty reconcile left unloaded while `currentFileID` still names the
            // departed file, without restarting a file that's already up.
            if coordinator.isLive(playlist), coordinator.currentFile(for: playlist)?.id != target.id {
                coordinator.jump(playlist, to: target)
            }
        } else {
            coordinator.reconcile(playlistThatChanged: playlist)
        }

        if managedPlaylist === playlist { reseedManagerSelection() }
    }

    /// The file the incoming filter's remembered position resolves to: the first file of the new
    /// playback sequence at or after the stored shuffle order, wrapping to the first when none
    /// qualify. `nil` — leaving the cursor untouched — when the active filter has no slot or no
    /// stored position yet (first visit / ad-hoc / service), or the sequence is empty.
    private func restoreTarget(for playlist: Playlist) -> PlaylistFile? {
        guard let stored = playlist.activeResumeSortOrder, let context = playlist.modelContext else { return nil }
        return context.resumeTarget(of: playlist, atOrAfter: stored)
    }

    /// Re-centers the Manager on the managed playlist's cursor — the selection re-seed a scope
    /// switch and a filter change share: highlight the resume file when it survives the current
    /// filter, else clear, and bump the scroll token so the list re-centers either way.
    func reseedManagerSelection() {
        managerSelection = []
        if let playlist = managedPlaylist, let id = playlist.currentFileID,
           sequences.isMember(id, of: playlist) {
            managerSelection = [id]
        }
        scrollSelectionToken += 1
    }
}
