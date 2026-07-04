//
//  AppMigrationPlan.swift
//  ShuTaPla
//
//  Registers the schema versions and the migration stages that carry an existing on-disk store
//  between them. Currently a single baseline (`SchemaV5`) with no stages. The next schema change
//  appends its pinned `SchemaVN` and a stage here — see `doc/versioning.md` for the recipe.
//
//  Tags and tagging status are filename-derived and repopulate on the next scan, so they are never
//  migrated as data; that keeps additive column/index changes eligible for a `.lightweight` stage.
//

import Foundation
import SwiftData

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV5.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
