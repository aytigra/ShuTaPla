//
//  SchemaV9.swift
//  ShuTaPla
//
//  The current schema: the live top-level models plus the standalone `SchemaMarker` entity. The
//  models reference the live types, so this version always tracks whatever they declare. V9 adds
//  PlaylistFile's HDR columns — `isHDR` (the badge fact, both media types) and the video colour
//  strings `hdrGamma`/`hdrPrimaries` — as additive optionals, so the V8→V9 stage is lightweight and
//  existing rows open with them `nil`, repopulating on next display (see `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self,
         SchemaMarker.self]
    }
}
