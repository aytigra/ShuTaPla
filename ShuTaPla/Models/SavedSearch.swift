//
//  SavedSearch.swift
//  ShuTaPla
//
//  Embedded value type stored on `Playlist`. A remembered tag search — a unique
//  tag-set + operator combination, each carrying its own playback resume position.
//  Re-applying an existing one moves it to the top instead of duplicating.
//

import Foundation

nonisolated struct SavedSearch: Codable, Sendable, Hashable, Identifiable {
    /// Stable identity for list display, independent of the tags/operator (which a
    /// playlist-wide tag rename can rewrite). Equality/dedup use `matches`, not this.
    let id: UUID
    var tags: [String]
    var mode: FilterMode

    /// The playback resume position last played under this search, as a point on the playlist's
    /// shuffle axis (`PlaylistFile.sortOrder`). `nil` until played under, and cleared by Reshuffle.
    var resumeSortOrder: Int?

    init(id: UUID = UUID(), tags: [String], mode: FilterMode, resumeSortOrder: Int? = nil) {
        self.id = id
        self.tags = tags
        self.mode = mode
        self.resumeSortOrder = resumeSortOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Searches saved before the stable id are minted one on read.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tags = try container.decode([String].self, forKey: .tags)
        mode = try container.decode(FilterMode.self, forKey: .mode)
        // Absent in searches saved before per-filter resume positions.
        resumeSortOrder = try container.decodeIfPresent(Int.self, forKey: .resumeSortOrder)
    }

    /// Two searches are the same combination when they cover the same tag set
    /// (order-insensitive) under the same operator.
    func matches(_ other: SavedSearch) -> Bool {
        mode == other.mode && Set(tags) == Set(other.tags)
    }
}
