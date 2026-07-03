//
//  LegacyPlaylistPreferences.swift
//  ShuTaPla
//
//  The `PlaylistPreferences` shape stored by SchemaV1–V4, before the live struct gained
//  `galleryMinItemWidth`.
//
//  `Playlist.preferences` is a single Codable struct property, so SwiftData persists it as a
//  *structured composite attribute* — its member fields are part of the entity's schema hash,
//  not an opaque blob. Adding a field therefore changes the schema, so the frozen schemas must
//  pin the *old* member set; they reference this type instead of the live struct (which now
//  carries the extra field). SwiftData records the composite by the value type's simple name
//  (`PlaylistPreferences`) and its stored fields, both reproduced here; only the current
//  SchemaV5 uses the live struct.
//

import Foundation

enum LegacySchema {
    nonisolated struct PlaylistPreferences: Codable, Sendable, Equatable {
        var volume: Float = 1.0
        var slideshowEnabled: Bool = false
        var slideshowInterval: TimeInterval?
        var imageFitMode: ImageFitMode?
        var filePositionPersistence: Bool?
        var viewMode: ViewMode = .list

        init() {}
    }
}
