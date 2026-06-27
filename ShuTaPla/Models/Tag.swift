//
//  Tag.swift
//  ShuTaPla
//
//  A tag, normalized for querying. Tags are shared many-to-many across files (and
//  across playlists), deduped case-insensitively by their normalized name, so a tag
//  filter can be a store-side `#Predicate` over the relationship rather than a per-file
//  walk of an inline string blob. The on-disk filename stays the source of truth for a
//  file's tags; this relationship mirrors the parsed tokens.
//

import Foundation
import SwiftData

@Model
final class Tag {
    /// Lowercased identity — the one key tags are deduped and queried by.
    @Attribute(.unique) var normalizedName: String = ""

    /// First-seen casing, for any surface that reads the shared tag rather than a file's
    /// own filename tokens (the filter dropdown, frequency, chips).
    var name: String = ""

    /// The files carrying this tag (inverse of `PlaylistFile.tags`).
    @Relationship var files: [PlaylistFile] = []

    init(name: String, normalizedName: String) {
        self.name = name
        self.normalizedName = normalizedName
    }
}
