//
//  SchemaVersionHashTests.swift
//  ShuTaPlaTests
//
//  Freezes the entity version hashes of every registered schema version.
//
//  A version hash is what CoreData writes into a store's `Z_METADATA` and compares an existing store
//  against to decide which migration stage applies. A pinned `SchemaVN` must therefore keep the exact
//  hash the shipped release wrote — if pinning, renaming or re-nesting a type shifts it, stores in the
//  field stop matching any registered version and the plan can no longer place them.
//
//  `SchemaIndexMigrationTests` cannot catch that: it writes with the pinned copies and reads with
//  them, so a shifted hash moves both sides together and the migration still succeeds. Only golden
//  values captured from the released shape hold a pinned version still.
//

import Testing
import Foundation
import SwiftData
import SQLite3
@testable import ShuTaPla

/// The entity version hashes CoreData recorded in a fresh store created at `schema`, keyed by entity
/// name and base64-encoded. Creating the container is enough — the store's metadata is written when
/// the schema is materialized, so no rows are inserted and nothing is fetched (which also keeps every
/// pinned same-named `@Model` out of the entity-name→type cast trap, see CLAUDE.md).
@MainActor
private func recordedVersionHashes(for schema: Schema) throws -> [String: String] {
    let url = URL.temporaryDirectory.appending(path: "schema-hash-\(UUID().uuidString).store")
    defer { try? FileManager.default.removeItem(at: url) }

    // Scoped so the container is released and the SQLite file flushed before it is read back.
    do {
        _ = try ModelContainer(for: schema, migrationPlan: nil,
                               configurations: [ModelConfiguration(schema: schema, url: url)])
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        return [:]
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT Z_PLIST FROM Z_METADATA", -1, &stmt, nil) == SQLITE_OK else {
        return [:]
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return [:] }

    let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
    let metadata = try PropertyListSerialization.propertyList(from: blob, format: nil)
    guard let metadata = metadata as? [String: Any],
          let hashes = metadata["NSStoreModelVersionHashes"] as? [String: Data]
    else { return [:] }
    return hashes.mapValues { $0.base64EncodedString() }
}

/// One registered version and the hashes it must keep producing. `Tag`, `AppStateModel` and
/// `GlobalSettings` have held their shape since V5, so they are stated once; the fields carry what a
/// version changed — `PlaylistFile` up to V9, `Playlist` and the two tag-filter entities at V10 —
/// and V5 alone predates the `SchemaMarker` entity.
struct FrozenVersion: Sendable, CustomTestStringConvertible {
    let schema: any VersionedSchema.Type
    let playlistFile: String
    var playlist: String = "+Syyi8SuizZHGlmqVv3pWQQx5bYagRJG9LBkYKqgPfk="
    var hasMarker: Bool = true

    /// Entities a version adds beyond the set every version carries.
    var added: [String: String] = [:]

    var testDescription: String { "\(schema.versionIdentifier)" }

    var expected: [String: String] {
        var hashes = [
            "Playlist": playlist,
            "PlaylistFile": playlistFile,
            "Tag": "E0DhhGkY30kMV+o7lyen9E66B0BhtSn/nB05WmSjQ/o=",
            "AppStateModel": "/eXp6xqxzK5SgkCjEvhKkOS+xkEEQpcRlwEOsj3G+Ak=",
            "GlobalSettings": "XsoyMm78PCaAI41nREZ51vpXTJIJRJ3hXORaL9nuByk=",
        ]
        if hasMarker { hashes["SchemaMarker"] = "Jk0p+C673rkEM4pRAyqjdsrSJ5aieJBrV7Zz47gwWg4=" }
        return hashes.merging(added) { _, new in new }
    }
}

@MainActor
struct SchemaVersionHashTests {

    /// V5 and V6 share a `PlaylistFile` hash: V6's only change to that entity is its `#Index`, and a
    /// fetch index is excluded from the version hash — the very reason V6 needs `SchemaMarker` to
    /// perturb the store hash so the stage runs at all (see `doc/versioning.md`). V10 is the mirror
    /// case: `PlaylistFile` is untouched there, and it is `Playlist` that moves.
    @Test(arguments: [
        FrozenVersion(schema: SchemaV5.self,
                      playlistFile: "VomwoKjWYSS89toSTDBnQxpLxoO7esrxE1mGHAQJce4=", hasMarker: false),
        FrozenVersion(schema: SchemaV6.self,
                      playlistFile: "VomwoKjWYSS89toSTDBnQxpLxoO7esrxE1mGHAQJce4="),
        FrozenVersion(schema: SchemaV7.self,
                      playlistFile: "nir+43ZiOzK7wSp+D2RO0y4hLeuzjuoqg7c+eU+/yyU="),
        FrozenVersion(schema: SchemaV8.self,
                      playlistFile: "DXbxSdxCinupk9yJIfUz7Sl6ItwMlYY74Bfv4xAkjkw="),
        FrozenVersion(schema: SchemaV9.self,
                      playlistFile: "9Wy/iDW8AifPJqO/FRLhcN2WbxHqqpqDHipU3ZJdT/Y="),
        FrozenVersion(schema: SchemaV10.self,
                      playlistFile: "9Wy/iDW8AifPJqO/FRLhcN2WbxHqqpqDHipU3ZJdT/Y=",
                      playlist: "TIs20oBjd28Snd3A1uz3saaPmfrF/4+Qv5EqHTtnyfg=",
                      added: ["TagFilter": "cJTMF3pHWyldD7fPUodQtyvhTdc4HT4/2IrynwdeEv8=",
                              "SavedSearch": "T8OgOQYxisJfKTW6UsldzuR+PKx9YZ1hconD1PMpvMM="]),
    ])
    func versionHashesAreFrozen(_ frozen: FrozenVersion) throws {
        let recorded = try recordedVersionHashes(for: Schema(versionedSchema: frozen.schema))
        #expect(recorded == frozen.expected)
    }
}
