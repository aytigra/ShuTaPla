//
//  SchemaV5.swift
//  ShuTaPla
//
//  The current schema — the sole version. Its models are the live top-level types, so this
//  version always tracks whatever they declare. Numbered 5 to match the `Schema.Version` already
//  stamped in existing stores; adding the next version pins this shape and bumps to 6 (see
//  `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self]
    }
}
