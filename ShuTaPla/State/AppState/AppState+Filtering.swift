//
//  AppState+Filtering.swift
//  ShuTaPla
//
//  The filter and saved-search orchestration: each wrapper edits the *given* playlist's persisted
//  filter state (the pure transitions live on `FilterState`/`Playlist`) and then settles the
//  surfaces through `filterChanged` — restore the incoming filter's remembered cursor, follow a
//  live channel to it, and re-center the managed selection.
//

import Foundation

extension AppState {

    /// Toggles a triage filter on `playlist`.
    func toggleServiceFilter(_ filter: ServiceFilter, on playlist: Playlist) {
        playlist.filterState.toggle(service: filter)
        filterChanged(on: playlist)
    }

    /// Adds or removes a tag from `playlist`'s tag filter.
    func toggleFilterTag(_ tag: String, on playlist: Playlist) {
        playlist.filterState.toggle(tag: tag)
        filterChanged(on: playlist)
    }

    /// Replaces `playlist`'s tag filter with a single tag.
    func setTagFilter(to tag: String, on playlist: Playlist) {
        playlist.filterState.setOnly(tag: tag)
        filterChanged(on: playlist)
    }

    /// Sets the AND/OR operator on `playlist`'s tag filter.
    func setFilterMode(_ mode: FilterMode, on playlist: Playlist) {
        playlist.filterState.filterMode = mode
        filterChanged(on: playlist)
    }

    /// Clears `playlist`'s tag filter.
    func clearTagFilter(on playlist: Playlist) {
        playlist.filterState.clearTags()
        filterChanged(on: playlist)
    }

    /// Remembers `playlist`'s current tag filter as a saved search.
    func saveCurrentSearch(on playlist: Playlist) {
        playlist.saveCurrentSearch()
    }

    /// Re-applies a saved search on `playlist` and settles the cursor onto it.
    func applySavedSearch(_ search: SavedSearch, on playlist: Playlist) {
        playlist.applySavedSearch(search)
        filterChanged(on: playlist)
    }

    /// Removes a saved search from `playlist`'s recents.
    func removeSavedSearch(_ search: SavedSearch, on playlist: Playlist) {
        playlist.removeSavedSearch(search)
    }

    /// Settles a playlist into the incoming filter after its `filterState` was edited. The new
    /// filter is persisted first so the store-side sequence reflects it, then the incoming filter's
    /// remembered slot is restored onto `currentFileID`: a live channel follows to that file (audio
    /// switches tracks now, a suppressed visual pre-loads), while a filter with no stored position
    /// falls back to the reconcile (advance only if the current file left the set). The managed
    /// playlist re-centers its selection on the resulting cursor.
    private func filterChanged(on playlist: Playlist) {
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
        guard let stored = playlist.activeResumeSortOrder else { return nil }
        let sequence = playlist.playbackFiles
        guard !sequence.isEmpty else { return nil }
        return sequence.first { $0.sortOrder >= stored } ?? sequence.first
    }

    /// Re-centers the Manager on the managed playlist's cursor — the selection re-seed a scope
    /// switch and a filter change share: highlight the resume file when it survives the current
    /// filter, else clear, and bump the scroll token so the list re-centers either way.
    func reseedManagerSelection() {
        managerSelection = []
        if let playlist = managedPlaylist, let id = playlist.currentFileID,
           displaySequenceContains(id, of: playlist) {
            managerSelection = [id]
        }
        scrollSelectionToken += 1
    }
}
