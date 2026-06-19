//
//  SavedSearch.swift
//  ShuTaPla
//
//  Embedded value type stored on `Playlist`. A remembered multi-tag search:
//  the 10 most recent unique combinations. Re-applying an existing one moves
//  it to the top instead of duplicating.
//

import Foundation

nonisolated struct SavedSearch: Codable, Sendable, Hashable, Identifiable {
    /// Stable identity for list display, independent of the tags/operator (which a
    /// playlist-wide tag rename can rewrite). Equality/dedup use `matches`, not this.
    let id: UUID
    var tags: [String]
    var mode: FilterMode

    init(id: UUID = UUID(), tags: [String], mode: FilterMode) {
        self.id = id
        self.tags = tags
        self.mode = mode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Searches saved before the stable id are minted one on read.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tags = try container.decode([String].self, forKey: .tags)
        mode = try container.decode(FilterMode.self, forKey: .mode)
    }

    /// Two searches are the same combination when they cover the same tag set
    /// (order-insensitive) under the same operator.
    func matches(_ other: SavedSearch) -> Bool {
        mode == other.mode && Set(tags) == Set(other.tags)
    }
}
