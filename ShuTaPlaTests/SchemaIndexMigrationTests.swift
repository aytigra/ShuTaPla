//
//  SchemaIndexMigrationTests.swift
//  ShuTaPlaTests
//
//  Guards the two lightweight migrations that a store rides through:
//
//  - V5→V6 ships PlaylistFile's `#Index`. A fetch index is excluded from CoreData's entity version
//    hash, so an index-only change never reaches a store that already exists — the migration would be
//    skipped and the index never built. SchemaV6 pairs the index with a standalone `SchemaMarker`
//    entity whose presence flips the store hash, so the lightweight stage runs and materializes the
//    index (see `doc/versioning.md`).
//  - V6→V7 adds PlaylistFile's additive optional `fingerprint` column. The column change flips the
//    hash on its own, so the lightweight stage runs; existing rows survive and open with
//    `fingerprint == nil`, repopulating on next display.
//  - V7→V8 adds PlaylistFile's additive optional `lastModified` column (the mtime half of the
//    thumbnail staleness gate) the same way; existing rows survive, keep their `fingerprint`, and
//    open with `lastModified == nil`.
//
//  Each test lays down a store at the pinned pre-change shape, releases that container so it
//  flushes and closes the SQLite file, then reopens the same URL through the migration plan and
//  asserts from the store itself. Verification is read straight from SQLite (`sqlite_master`,
//  `PRAGMA table_info`, `SELECT`): with V5, V6, and live PlaylistFile copies all present in the
//  process, a model fetch would trip SwiftData's entity-name→type cast (see the duplicate-model-name
//  trap in CLAUDE.md), so no fetch is done at all.
//

import Testing
import Foundation
import SwiftData
import SQLite3
@testable import ShuTaPla

/// Opens the store read-only and runs `body` with the SQLite handle, closing it after. Every
/// verification below is a query against the materialized store — the ground truth for what the
/// migration actually wrote.
private func withStore<T>(at url: URL, _ body: (OpaquePointer) -> T, default fallback: T) -> T {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        return fallback
    }
    defer { sqlite3_close(db) }
    return body(db)
}

/// The text values of a single-column query, in row order.
private func stringColumn(atStore url: URL, query: String) -> [String] {
    withStore(at: url, { db in
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }, default: [])
}

/// The integer result of a scalar query (a `COUNT(*)`), or `-1` when the store can't be read.
private func scalarInt(atStore url: URL, query: String) -> Int {
    withStore(at: url, { db in
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }, default: -1)
}

private func rowCount(atStore url: URL, table: String) -> Int {
    scalarInt(atStore: url, query: "SELECT COUNT(*) FROM \(table)")
}

/// Filenames ordered on the shuffle axis — the row-survival + ordering check without a model fetch.
private func orderedFileNames(atStore url: URL) -> [String] {
    stringColumn(atStore: url, query: "SELECT ZFILENAME FROM ZPLAYLISTFILE ORDER BY ZSORTORDER")
}

/// Whether `table` has `column`. CoreData mangles our names to `Z`-prefixed uppercase
/// (`fingerprint` → `ZFINGERPRINT`); `PRAGMA table_info` is the ground truth for the column set.
private func hasColumn(atStore url: URL, table: String, column: String) -> Bool {
    withStore(at: url, { db in
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }, default: false)
}

/// The `CREATE INDEX` statements SwiftData emitted into the store's SQLite file.
private func indexDDL(atStore url: URL) -> [String] {
    stringColumn(atStore: url, query: "SELECT sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL")
}

/// True iff some index covers the `(playlist, …, sortOrder)` sequence path — an index whose DDL
/// mentions both the playlist relationship column and the `sortOrder` sort column.
private func hasSequenceIndex(atStore url: URL) -> Bool {
    indexDDL(atStore: url).contains { $0.contains("ZSORTORDER") && $0.contains("ZPLAYLIST") }
}

@MainActor
struct SchemaIndexMigrationTests {

    /// A pre-index V5 store with three files (one tagged, one skipped) migrates to V6, keeping its
    /// rows and gaining the sequence index. Written at the pinned pre-index shape, then reopened
    /// through SchemaV6 + `AppMigrationPlan`: the marker-entity hash change makes the lightweight
    /// stage run and reconcile PlaylistFile's `#Index`. Everything is read from the store after the
    /// reopened container is released, so the file is flushed and settled.
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

        // Phase 2 — reopen through V6 + the plan, then release so the store flushes before reads.
        do {
            let schema = Schema(versionedSchema: SchemaV6.self)
            _ = try ModelContainer(
                for: schema, migrationPlan: AppMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url)])
        }
        #expect(hasSequenceIndex(atStore: url), "the V5→V6 migration materializes the index")
        #expect(rowCount(atStore: url, table: "ZPLAYLISTFILE") == 3, "every row survives")
        #expect(orderedFileNames(atStore: url) == ["a [beach].jpg", "b.jpg", "skip.txt"],
                "rows survive in shuffle order")
        #expect(stringColumn(atStore: url,
            query: "SELECT ZFILENAME FROM ZPLAYLISTFILE WHERE ZISSKIPPED = 1") == ["skip.txt"],
                "the skipped flag survives")
        #expect(rowCount(atStore: url, table: "ZTAG") == 1, "the tag row survives")
    }

    /// A V6 store migrates to V7, keeping its rows and gaining PlaylistFile's `fingerprint` column,
    /// which every migrated row opens with as `nil` (it repopulates on next gallery display).
    /// Written at the pinned pre-fingerprint shape, then reopened through SchemaV7 + `AppMigrationPlan`.
    @Test func migratingAV6StoreAddsTheFingerprintColumn() throws {
        let url = URL.temporaryDirectory.appending(path: "schema-fp-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Phase 1 — write at the pre-fingerprint shape, then let the container go so it flushes.
        do {
            let schema = Schema(versionedSchema: SchemaV6.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: nil,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = container.mainContext
            let playlist = SchemaV6.Playlist(
                name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
            context.insert(playlist)
            for (i, name) in ["a.jpg", "b.jpg"].enumerated() {
                let file = SchemaV6.PlaylistFile(relativePath: name, fileName: name, sortOrder: i)
                file.playlist = playlist
                context.insert(file)
            }
            try context.save()
        }
        #expect(!hasColumn(atStore: url, table: "ZPLAYLISTFILE", column: "ZFINGERPRINT"),
                "the V6 store has no fingerprint column")

        // Phase 2 — reopen through V7 + the plan, then release so the store flushes before reads.
        do {
            let schema = Schema(versionedSchema: SchemaV7.self)
            _ = try ModelContainer(
                for: schema, migrationPlan: AppMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url)])
        }
        #expect(hasColumn(atStore: url, table: "ZPLAYLISTFILE", column: "ZFINGERPRINT"),
                "the V6→V7 migration adds the fingerprint column")
        #expect(rowCount(atStore: url, table: "ZPLAYLISTFILE") == 2, "every row survives")
        #expect(orderedFileNames(atStore: url) == ["a.jpg", "b.jpg"], "scalar data survives in order")
        #expect(scalarInt(atStore: url,
            query: "SELECT COUNT(*) FROM ZPLAYLISTFILE WHERE ZFINGERPRINT IS NOT NULL") == 0,
                "migrated rows open with fingerprint == nil")
    }

    /// A V7 store migrates to V8, keeping its rows (and their `fingerprint` values) and gaining
    /// PlaylistFile's `lastModified` column, which every migrated row opens with as `nil` (it
    /// repopulates when the thumbnail producer next examines the file). Written at the pinned
    /// pre-`lastModified` shape, then reopened through SchemaV8 + `AppMigrationPlan`.
    @Test func migratingAV7StoreAddsTheLastModifiedColumn() throws {
        let url = URL.temporaryDirectory.appending(path: "schema-mtime-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Phase 1 — write at the pre-`lastModified` shape (with fingerprints set), then release.
        do {
            let schema = Schema(versionedSchema: SchemaV7.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: nil,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = container.mainContext
            let playlist = SchemaV7.Playlist(
                name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
            context.insert(playlist)
            for (i, name) in ["a.jpg", "b.jpg"].enumerated() {
                let file = SchemaV7.PlaylistFile(relativePath: name, fileName: name, sortOrder: i)
                file.fingerprint = "fp\(i)"
                file.playlist = playlist
                context.insert(file)
            }
            try context.save()
        }
        #expect(!hasColumn(atStore: url, table: "ZPLAYLISTFILE", column: "ZLASTMODIFIED"),
                "the V7 store has no lastModified column")

        // Phase 2 — reopen through V8 + the plan, then release so the store flushes before reads.
        do {
            let schema = Schema(versionedSchema: SchemaV8.self)
            _ = try ModelContainer(
                for: schema, migrationPlan: AppMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url)])
        }
        #expect(hasColumn(atStore: url, table: "ZPLAYLISTFILE", column: "ZLASTMODIFIED"),
                "the V7→V8 migration adds the lastModified column")
        #expect(rowCount(atStore: url, table: "ZPLAYLISTFILE") == 2, "every row survives")
        #expect(orderedFileNames(atStore: url) == ["a.jpg", "b.jpg"], "scalar data survives in order")
        #expect(scalarInt(atStore: url,
            query: "SELECT COUNT(*) FROM ZPLAYLISTFILE WHERE ZLASTMODIFIED IS NOT NULL") == 0,
                "migrated rows open with lastModified == nil")
        #expect(scalarInt(atStore: url,
            query: "SELECT COUNT(*) FROM ZPLAYLISTFILE WHERE ZFINGERPRINT IS NOT NULL") == 2,
                "the fingerprint survives the migration")
    }
}
