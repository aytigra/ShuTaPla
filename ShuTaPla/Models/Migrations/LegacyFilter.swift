//
//  LegacyFilter.swift
//  ShuTaPla
//
//  The tag filter as `SchemaV5`–`SchemaV8` store it: a composite attribute on `Playlist`
//  (`filterState`) and the saved-search blob beside it (`savedSearches`). Pinned copies, so those
//  versions keep their frozen shape no matter what the live filter types become.
//
//  One set rather than one per version: the shape never moved across V5–V8, and a version that does
//  move it declares its own. Only stored members and the defaults the pinned models need are here —
//  behaviour belongs to the live types, and a historical shape has no behaviour to keep.
//

import Foundation

nonisolated enum LegacyFilter {

    struct State: Codable, Sendable {
        var selectedTags: [String] = []
        var filterMode: Mode = .and
        var serviceFilter: ServiceFilter?

        init() {}
    }

    struct SavedSearch: Codable, Sendable {
        let id: UUID
        var tags: [String]
        var mode: Mode
        var resumeSortOrder: Int?
    }

    enum Mode: String, Codable, Sendable {
        case and
        case or
        case notAll
        case notAny
    }
}
