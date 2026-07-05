//
//  AppMigrationPlan.swift
//  ShuTaPla
//
//  Registers the schema versions and the migration stages that carry an existing on-disk store
//  between them. The V5→V6 stage is lightweight: SchemaV6 adds the standalone `SchemaMarker` entity
//  (and PlaylistFile's `#Index`), which flips the store hash so the migration runs and the index is
//  materialized on existing stores. The V6→V7 stage is lightweight too: SchemaV7 adds PlaylistFile's
//  additive optional `fingerprint` column, which existing rows open with as `nil` and repopulate on
//  next display. The next schema change appends its pinned `SchemaVN` and a stage here — see
//  `doc/versioning.md` for the recipe.
//
//  Tags and tagging status are filename-derived and repopulate on the next scan, so they are never
//  migrated as data; that keeps additive column/index changes eligible for a `.lightweight` stage.
//

import Foundation
import SwiftData

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV5.self, SchemaV6.self, SchemaV7.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self),
         .lightweight(fromVersion: SchemaV6.self, toVersion: SchemaV7.self)]
    }
}
