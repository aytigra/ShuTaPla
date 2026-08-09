//
//  AppMigrationPlan.swift
//  ShuTaPla
//
//  Registers the schema versions and the migration stages that carry an existing on-disk store
//  between them. The V5→V6 stage is lightweight: SchemaV6 adds the standalone `SchemaMarker` entity
//  (and PlaylistFile's `#Index`), which flips the store hash so the migration runs and the index is
//  materialized on existing stores. The V6→V7 stage is lightweight too: SchemaV7 adds PlaylistFile's
//  additive optional `fingerprint` column, which existing rows open with as `nil` and repopulate on
//  next display. The V7→V8 stage is lightweight too: SchemaV8 adds PlaylistFile's additive optional
//  `lastModified` column (the mtime half of the thumbnail staleness gate), opened as `nil` and
//  repopulated on next display. The V8→V9 stage is lightweight too: SchemaV9 adds PlaylistFile's additive
//  optional HDR columns — `isHDR` (the badge fact for both media types) and the video colour strings
//  `hdrGamma`/`hdrPrimaries` — opened as `nil` and repopulated on next display. The V9→V10 stage is
//  lightweight too, and the only one that *removes* shape: SchemaV10 turns the tag filter into store
//  rows — the `TagFilter` and `SavedSearch` entities plus Playlist's two relationships and its
//  `serviceFilterRaw` column — and drops Playlist's `filterState` composite and `savedSearches` blob.
//  A dropped column and an added entity are both supported lightweight changes. Filters are cheap to
//  re-enter, so nothing is carried across: an existing playlist opens unfiltered with no saved
//  searches.
//  The next schema change appends its pinned `SchemaVN` and a stage
//  here — see `doc/versioning.md` for the recipe.
//
//  Tags and tagging status are filename-derived and repopulate on the next scan, so they are never
//  migrated as data; that keeps additive column/index changes eligible for a `.lightweight` stage.
//

import Foundation
import SwiftData

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV5.self, SchemaV6.self, SchemaV7.self, SchemaV8.self, SchemaV9.self, SchemaV10.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self),
         .lightweight(fromVersion: SchemaV6.self, toVersion: SchemaV7.self),
         .lightweight(fromVersion: SchemaV7.self, toVersion: SchemaV8.self),
         .lightweight(fromVersion: SchemaV8.self, toVersion: SchemaV9.self),
         .lightweight(fromVersion: SchemaV9.self, toVersion: SchemaV10.self)]
    }
}
