//
//  SchemaIndexMigrationTests.swift
//  ShuTaPlaTests
//
//  Guards the V5→V6 migration that ships PlaylistFile's `#Index`. A fetch index is excluded from
//  CoreData's entity version hash, so an index-only change never reaches a store that already
//  exists — the migration is skipped as a no-op and the index is never built. SchemaV6 pairs the
//  index with a standalone `SchemaMarker` entity whose presence flips the store hash, so the
//  lightweight stage runs and materializes the index on existing stores (see `doc/versioning.md`).
//
//  The test lays down a store at the pinned pre-index shape (`SchemaV5`), releases that container so
//  it flushes and closes the SQLite file, then reopens the same URL through SchemaV6 + the migration
//  plan and asserts the rows survived and the index now exists. The index is read straight from the
//  store's `sqlite_master` — the ground truth for whether `#Index` actually materialized.
//

import Testing
import Foundation
import SwiftData
import SQLite3
@testable import ShuTaPla

/// The `CREATE INDEX` statements SwiftData emitted into the store's SQLite file. CoreData mangles
/// our columns to `Z`-prefixed uppercase (`sortOrder` → `ZSORTORDER`), so an index over the
/// sequence path shows up as DDL mentioning `ZSORTORDER`.
private func indexDDL(atStore url: URL) -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(
        db, "SELECT sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL", -1, &stmt, nil
    ) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var out: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
    }
    return out
}

/// True iff some index covers the `(playlist, …, sortOrder)` sequence path — an index whose DDL
/// mentions both the playlist relationship column and the `sortOrder` sort column.
private func hasSequenceIndex(atStore url: URL) -> Bool {
    indexDDL(atStore: url).contains { $0.contains("ZSORTORDER") && $0.contains("ZPLAYLIST") }
}

/// The row count of a store table — a data-survival check that avoids a model fetch/cast.
private func rowCount(atStore url: URL, table: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK
    else { return -1 }
    defer { sqlite3_finalize(stmt) }
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
}

@MainActor
struct SchemaIndexMigrationTests {

    /// A pre-index V5 store with three files (one tagged, one skipped) migrates to V6, keeping its
    /// rows and gaining the sequence index. Written at the pinned pre-index shape, then reopened
    /// through SchemaV6 + `AppMigrationPlan`: the marker-entity hash change makes the lightweight
    /// stage run and reconcile PlaylistFile's `#Index`. The index is read from `sqlite_master` after
    /// the reopened container is released, so the file is flushed and settled.
    @Test func migratingAV5StoreAddsTheSequenceIndex() throws {
        let url = URL.temporaryDirectory.appending(path: "schema-index-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Phase 1 — write at the pre-index shape, then let the container go so it flushes/closes.
        do {
            let schema = Schema(versionedSchema: SchemaV5.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: nil,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = container.mainContext
            let playlist = SchemaV5.Playlist(
                name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
            context.insert(playlist)
            let beach = SchemaV5.Tag(name: "beach", normalizedName: "beach")
            context.insert(beach)
            for (i, name) in ["a [beach].jpg", "b.jpg", "skip.txt"].enumerated() {
                let file = SchemaV5.PlaylistFile(
                    relativePath: name, fileName: name, isSkipped: name == "skip.txt", sortOrder: i)
                file.playlist = playlist
                if name.contains("beach") { file.tags = [beach] }
                context.insert(file)
            }
            try context.save()
        }
        #expect(!hasSequenceIndex(atStore: url), "the V5 store starts without the index")

        // Phase 2 — reopen through V6 + the plan. The lightweight stage runs (SchemaMarker flips the
        // hash), preserving the rows; the index materializes. Fetch verifies the rows survived in
        // order with their relationships; the index is read after the container is released.
        do {
            let schema = Schema(versionedSchema: SchemaV6.self)
            let reopened = try ModelContainer(
                for: schema, migrationPlan: AppMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let files = try reopened.mainContext.fetch(
                FetchDescriptor<PlaylistFile>(sortBy: [SortDescriptor(\.sortOrder)]))
            #expect(files.map(\.fileName) == ["a [beach].jpg", "b.jpg", "skip.txt"])
            #expect(files.first?.tags.map(\.name) == ["beach"])
            #expect(files.last?.isSkipped == true)
        }
        #expect(hasSequenceIndex(atStore: url), "the V5→V6 migration materializes the index")
        #expect(rowCount(atStore: url, table: "ZPLAYLISTFILE") == 3, "every row survives")
    }
}
