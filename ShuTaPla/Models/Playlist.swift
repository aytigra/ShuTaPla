//
//  Playlist.swift
//  ShuTaPla
//
//  A lightweight index into a folder of media. Ordering, position, and
//  preferences are persisted; everything else is derived from disk on scan.
//

import Foundation
import SwiftData

@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String = ""

    /// Security-scoped bookmark — the persistent access grant to the folder.
    var folderBookmark: Data = Data()

    /// Display-only path, not used for access.
    var folderPath: String = ""

    var mediaType: MediaType = MediaType.video

    /// User-defined ordering within its sidebar section.
    var sortOrder: Int = 0

    /// Current / last-played file by ID — stays valid through Update
    /// prune/append, where an index would not.
    var currentFileID: UUID?

    /// Persisted per-playlist Stopped/Playing/Paused state. Suppression is a
    /// transient runtime layer on top of this and is never stored here.
    var playbackState: PlaybackState = PlaybackState.stopped

    var createdAt: Date = Date()

    // Embedded value type (JSON-encoded by SwiftData).
    var preferences: PlaylistPreferences = PlaylistPreferences()

    /// The tag filter applied right now, or nil when the playlist is unfiltered. Cascade-owned, but
    /// being applied is not ownership in the other direction: reassigning this fires no delete rule,
    /// so the outgoing row survives and only an *ad-hoc* one is deleted deliberately.
    @Relationship(deleteRule: .cascade, inverse: \TagFilter.playlist)
    var currentFilter: TagFilter?

    /// Unordered, as every SwiftData to-many is; `sortedSavedSearches` is what read sites use.
    @Relationship(deleteRule: .cascade, inverse: \SavedSearch.playlist)
    var savedSearches: [SavedSearch] = []

    /// The triage filter's `rawValue`, or nil for none. Stored as a string rather than the enum so a
    /// value no longer in `ServiceFilter` — a case removed in a later version — reads back as "no
    /// filter" instead of failing the attribute's decode. Independent of the tag filter: a tag
    /// filter set underneath survives a detour through triage.
    var serviceFilterRaw: String?

    /// Resume position for the unfiltered state, as a point on the shuffle axis
    /// (`PlaylistFile.sortOrder`). The no-filter counterpart of `SavedSearch.resumeSortOrder`;
    /// `nil` until played unfiltered, and cleared by Reshuffle.
    var unfilteredResumeSortOrder: Int?

    /// Per-playlist tag usage counts, drives filter/editor dropdown ordering.
    var tagFrequency: [String: Int] = [:]

    @Relationship(deleteRule: .cascade, inverse: \PlaylistFile.playlist)
    var files: [PlaylistFile] = []

    init(
        name: String,
        folderBookmark: Data,
        folderPath: String,
        mediaType: MediaType,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath
        self.mediaType = mediaType
        self.sortOrder = sortOrder
        self.playbackState = .stopped
        self.createdAt = Date()
    }

    /// `serviceFilterRaw` read as the enum — an unrecognized stored value reads as no filter.
    var serviceFilter: ServiceFilter? {
        get { serviceFilterRaw.flatMap(ServiceFilter.init(rawValue:)) }
        set { serviceFilterRaw = newValue?.rawValue }
    }
}
