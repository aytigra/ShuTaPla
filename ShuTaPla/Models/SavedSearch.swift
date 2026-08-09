//
//  SavedSearch.swift
//  ShuTaPla
//
//  A name and a remembered playback position over one `TagFilter`. Applying a search points the
//  playlist's `currentFilter` at the search's own filter row rather than a copy, so editing the
//  filter edits the search — there is no commit step, and `currentFilter?.savedSearch` is what
//  "which search is active" means (nil ⇒ ad-hoc).
//

import Foundation
import SwiftData

@Model
final class SavedSearch {
    /// Stands in for a name the user left blank, so no display site nil-coalesces or renders an
    /// empty row.
    nonisolated static let defaultName = "Unnamed search"

    /// Non-optional with a default, so no display site nil-coalesces. Several searches may share a
    /// name; the tags of their filter, shown under it, are what tell them apart.
    var name: String = SavedSearch.defaultName

    /// Stable insertion order, not most-recently-used — applying a search never reorders the list
    /// under the user; only the explicit reorder control rewrites it. Every read site sorts by it,
    /// because `Playlist.savedSearches` is unordered as every SwiftData to-many is.
    var listOrder: Int = 0

    /// The playback position last played under this search, as a point on the playlist's shuffle
    /// axis (`PlaylistFile.sortOrder`). `nil` until played under, and cleared by Reshuffle.
    var resumeSortOrder: Int?

    /// The lists this search was saved over. Cascades both ways with `TagFilter.savedSearch`, so
    /// deleting either end reaps the pair.
    @Relationship(deleteRule: .cascade) var filter: TagFilter?

    var playlist: Playlist?

    init(name: String = SavedSearch.defaultName, listOrder: Int = 0, resumeSortOrder: Int? = nil) {
        self.name = name
        self.listOrder = listOrder
        self.resumeSortOrder = resumeSortOrder
    }
}
