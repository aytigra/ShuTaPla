//
//  Playlist+Resume.swift
//  ShuTaPla
//
//  The per-filter resume memory: the unfiltered state and every saved search each remember the
//  shuffle position (`PlaylistFile.sortOrder`) they were last played at, so switching filters lands
//  where that filter left off. Capture mirrors the playing file's position into whichever slot the
//  live filter selects; a filter change later reads the incoming slot to restore.
//
//  Ad-hoc filters earn no slot — you never switch *into* ad-hoc, and on relaunch `currentFileID`
//  resumes it — and neither do service filters.
//

import Foundation
import SwiftData

@MainActor
extension Playlist {
    /// The live filter's remembered position: the unfiltered slot when no tag filter is set, the
    /// active saved search's otherwise, and nil for an ad-hoc filter.
    ///
    /// The service-filter guard comes first so a triage filter answers **no slot** rather than
    /// inheriting whatever the tag filter underneath would answer — with a tag filter set that
    /// would be the search's slot, with none the unfiltered slot, and those are three different
    /// answers that only the guard separates.
    var activeResumeSortOrder: Int? {
        get {
            guard serviceFilter == nil else { return nil }
            guard let filter = currentFilter else { return unfilteredResumeSortOrder }
            return filter.savedSearch?.resumeSortOrder
        }
        set {
            guard serviceFilter == nil else { return }
            guard let filter = currentFilter else {
                unfilteredResumeSortOrder = newValue
                return
            }
            filter.savedSearch?.resumeSortOrder = newValue
        }
    }

    /// Mirrors `sortOrder` into the live filter's slot, keeping the outgoing filter's resume point
    /// current as playback moves. A no-op for ad-hoc and service filters.
    func captureResumePosition(_ sortOrder: Int) {
        activeResumeSortOrder = sortOrder
    }

    /// Voids every remembered position — the unfiltered slot and each saved search's — as a new
    /// shuffle axis (Reshuffle) invalidates positions keyed to the old one.
    func clearResumePositions() {
        unfilteredResumeSortOrder = nil
        for search in savedSearches { search.resumeSortOrder = nil }
    }
}
