//
//  SchemaV7.swift
//  ShuTaPla
//
//  The current schema: the live top-level models plus the standalone `SchemaMarker` entity. The
//  models reference the live types, so this version always tracks whatever they declare. V7 adds
//  PlaylistFile's `fingerprint` column — a content-derived identity that keys the thumbnail cache —
//  as an additive optional, so the V6→V7 stage is lightweight and existing rows open with
//  `fingerprint == nil`, repopulating on next display (see `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self,
         SchemaMarker.self]
    }
}
