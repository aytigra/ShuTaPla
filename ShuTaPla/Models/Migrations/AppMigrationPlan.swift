//
//  AppMigrationPlan.swift
//  ShuTaPla
//
//  The migration plan that carries an existing on-disk store forward across schema changes.
//  Tags and tagging status are derived from filenames and repopulate on the next scan, so they
//  are never migrated as data — which keeps every stage lightweight while the non-derivable rows
//  (playlists, bookmarks, preferences, positions, sort order) are preserved. Each version's
//  pinned schema lives in its own `SchemaVN.swift` alongside this file.
//

import Foundation
import SwiftData

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            // Carries an existing store forward to `SchemaV2`. The `Tag` relationship and
            // `taggingStatusCode` are filename-derived and rebuild on the next scan, so the stage is
            // lightweight: SwiftData drops the old inline `tags`/`taggingStatus` columns and adds the
            // `Tag` entity, the `tags` relationship, and `taggingStatusCode`, while every other row
            // is preserved untouched.
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
            // Carries a `SchemaV2` store forward to `SchemaV3` by adding the nilable
            // `Playlist.unfilteredResumeSortOrder` column; every other row is preserved untouched.
            .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
        ]
    }
}
