//
//  SchemaMarker.swift
//  ShuTaPla
//
//  An empty, permanent entity whose only job is to perturb the store's schema hash. SwiftData
//  excludes fetch indexes (`#Index`) from an entity's version hash, so adding an index alone never
//  reaches a store that already exists — CoreData deems the store already compatible and skips the
//  migration, leaving the index uncreated. A hash change on *any* entity makes the lightweight
//  migration run, and a running migration reconciles **every** entity's declared indexes. This
//  marker is that hash change: introduced alongside `PlaylistFile`'s `#Index`, kept forever
//  (removing it re-opens the skip), and the reusable lever for the next forgotten index — perturb
//  it (add or rename a property) in that release. See `doc/versioning.md`.
//

import Foundation
import SwiftData

@Model
final class SchemaMarker {
    var generation: Int = 0
    init() {}
}
