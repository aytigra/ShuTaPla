//
//  SchemaV6.swift
//  ShuTaPla
//
//  The current schema: the live top-level models plus the standalone `SchemaMarker` entity. The
//  models reference the live types, so this version always tracks whatever they declare. The
//  marker's presence is what flips the store hash against a V5 store, so the V5→V6 lightweight
//  stage runs and materializes PlaylistFile's `#Index` on stores that already exist — an
//  index-only change is hash-excluded and would be skipped (see `SchemaMarker`, `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self,
         SchemaMarker.self]
    }
}
