//
//  SchemaV4.swift
//  ShuTaPla
//
//  The current schema. Its models are the live top-level types.
//

import Foundation
import SwiftData

/// The current schema. Its models are the live top-level types.
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self]
    }
}
