//
//  Playlist+ResumeSlot.swift
//  ShuTaPla
//
//  The per-filter resume memory: each filter a playlist can hold — every saved search plus the
//  unfiltered state — owns a slot holding the shuffle position (`PlaylistFile.sortOrder`) it was
//  last played at. The active slot follows the live `filterState`: the unfiltered slot when no
//  tags and no service filter are set, the matching saved search otherwise. Ad-hoc tag filters
//  (never saved) and service filters earn no slot. Capture mirrors the playing file's position
//  into the active slot; a filter change later reads the incoming slot to restore.
//

import Foundation
import SwiftData

@MainActor
extension Playlist {
    /// Which filter's resume slot the current `filterState` selects: the unfiltered slot, or a
    /// saved search by index into `savedSearches`. `nil` for an ad-hoc tag filter (no matching
    /// saved search) or any service filter — neither earns a slot.
    enum ResumeSlot: Equatable {
        case unfiltered
        case savedSearch(Int)
    }

    var activeResumeSlot: ResumeSlot? {
        if filterState.serviceFilter != nil { return nil }
        if filterState.isEmpty { return .unfiltered }
        let current = SavedSearch(tags: filterState.selectedTags, mode: filterState.filterMode)
        guard let index = savedSearches.firstIndex(where: { $0.matches(current) }) else { return nil }
        return .savedSearch(index)
    }

    /// True when the live filter already equals a stored saved search. Saving it again would only
    /// re-promote that search, so the Save action is offered only when this is false.
    var isCurrentFilterSaved: Bool {
        if case .savedSearch = activeResumeSlot { return true }
        return false
    }

    /// The active filter's stored resume position, or `nil` when there is no slot or it is unset.
    var activeResumeSortOrder: Int? {
        switch activeResumeSlot {
        case .unfiltered: return unfilteredResumeSortOrder
        case .savedSearch(let index): return savedSearches[index].resumeSortOrder
        case nil: return nil
        }
    }

    /// Mirrors `sortOrder` into the active filter's slot, keeping the outgoing filter's resume
    /// point current as playback moves. A no-op for ad-hoc and service filters.
    func captureResumePosition(_ sortOrder: Int) {
        switch activeResumeSlot {
        case .unfiltered: unfilteredResumeSortOrder = sortOrder
        case .savedSearch(let index): savedSearches[index].resumeSortOrder = sortOrder
        case nil: break
        }
    }

    /// Voids every remembered resume position — the unfiltered slot and each saved search's — as a
    /// new shuffle axis (Reshuffle) invalidates positions keyed to the old one.
    func clearResumePositions() {
        unfilteredResumeSortOrder = nil
        savedSearches = savedSearches.map {
            var search = $0
            search.resumeSortOrder = nil
            return search
        }
    }
}
