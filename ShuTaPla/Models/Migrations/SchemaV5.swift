//
//  SchemaV5.swift
//  ShuTaPla
//
//  The current schema. Its models are the live top-level types.
//

import Foundation
import SwiftData

/// The current schema. Its models are the live top-level types, whose `Playlist.preferences`
/// carries the `galleryMinItemWidth` field added to the `PlaylistPreferences` composite.
enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self]
    }
}
