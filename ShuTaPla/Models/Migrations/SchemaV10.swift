//
//  SchemaV10.swift
//  ShuTaPla
//
//  The current schema: the live top-level models plus the two the four-field tag filter adds —
//  `TagFilter` and `SavedSearch`, now entities rather than a composite attribute and a blob on
//  `Playlist`. The models reference the live types, so this version always tracks whatever they
//  declare (see `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, TagFilter.self, SavedSearch.self,
         AppStateModel.self, GlobalSettings.self, SchemaMarker.self]
    }
}
