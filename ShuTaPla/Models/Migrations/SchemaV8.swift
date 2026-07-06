//
//  SchemaV8.swift
//  ShuTaPla
//
//  The current schema: the live top-level models plus the standalone `SchemaMarker` entity. The
//  models reference the live types, so this version always tracks whatever they declare. V8 adds
//  PlaylistFile's `lastModified` column — the mtime half of the thumbnail staleness gate — as an
//  additive optional, so the V7→V8 stage is lightweight and existing rows open with
//  `lastModified == nil`, repopulating on next display (see `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self,
         SchemaMarker.self]
    }
}
