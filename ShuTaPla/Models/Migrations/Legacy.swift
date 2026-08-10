//
//  Legacy.swift
//  ShuTaPla
//
//  The value types `SchemaV5`–`SchemaV9`'s `Playlist` stores, frozen: the filter composite
//  (`filterState`), the saved-search blob beside it, the preferences composite, and the two enums
//  the model stores directly. Pinned copies, so those versions keep their shape whatever the live
//  types become — a composite attribute's members are part of the entity hash and a raw-value enum
//  contributes its storage type, so a live type that gains a member or changes its raw type would
//  retroactively reshape a version that is no longer allowed to move.
//
//  Every value type a pinned model stores is here, with no exception to remember: an inert one (a
//  raw-value enum, which only a change of raw type could shift) sits beside a live one (a composite,
//  which any added field shifts) rather than being left to name the type it froze away from.
//
//  One set rather than one per version: the shape never moved across V5–V9, and a version that does
//  move it declares its own. Only stored members are here — behaviour belongs to the live types, and
//  a historical shape has no behaviour to keep. Naming and nesting are free, since the hash covers
//  the members' names and types but never the type's own name.
//

import Foundation

nonisolated enum Legacy {

    struct FilterState: Codable, Sendable {
        var selectedTags: [String] = []
        var filterMode: FilterMode = .and
        var serviceFilter: ServiceFilter?

        init() {}
    }

    struct SavedSearch: Codable, Sendable {
        let id: UUID
        var tags: [String]
        var mode: FilterMode
        var resumeSortOrder: Int?
    }

    struct Preferences: Codable, Sendable {
        var volume: Float = 1.0
        var slideshowEnabled: Bool = false
        var slideshowInterval: TimeInterval?
        var imageFitMode: ImageFitMode?
        var filePositionPersistence: Bool?
        var viewMode: ViewMode = .list
        var galleryMinItemWidth: Double?

        init() {}
    }

    enum FilterMode: String, Codable, Sendable {
        case and
        case or
        case notAll
        case notAny
    }

    enum ServiceFilter: String, Codable, Sendable {
        case untagged
        case invalidTagging
    }

    enum ImageFitMode: String, Codable, Sendable {
        case fit
        case cover
        case original
    }

    enum ViewMode: String, Codable, Sendable {
        case list
        case gallery
    }

    enum MediaType: String, Codable, Sendable {
        case video
        case image
        case audio
    }

    enum PlaybackState: String, Codable, Sendable {
        case stopped
        case playing
        case paused
    }
}
