//
//  SavedSearch.swift
//  ShuTaPla
//
//  Embedded value type stored on `Playlist`. A remembered multi-tag search:
//  the 10 most recent unique combinations. Re-applying an existing one moves
//  it to the top instead of duplicating.
//

import Foundation

nonisolated struct SavedSearch: Codable, Sendable, Hashable {
    var tags: [String]
    var mode: FilterMode

    init(tags: [String], mode: FilterMode) {
        self.tags = tags
        self.mode = mode
    }

    /// Two searches are the same combination when they cover the same tag set
    /// (order-insensitive) under the same operator.
    func matches(_ other: SavedSearch) -> Bool {
        mode == other.mode && Set(tags) == Set(other.tags)
    }
}
