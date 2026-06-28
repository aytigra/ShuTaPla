//
//  PersistentStore.swift
//  ShuTaPla
//
//  Builds the app's on-disk SwiftData container so launch can never get stuck on a
//  broken store. The library and its tags are rebuildable by re-scanning folders, so an
//  unreadable store left by an incompatible schema is discarded and recreated rather than
//  crashing the app.
//

import Foundation
import SwiftData

enum PersistentStore {
    /// Opens the on-disk container for `schema`/`configuration`, recovering instead of
    /// crashing when the existing store can't be read:
    ///
    /// 1. The store opens — the normal path.
    /// 2. It can't be opened (an incompatible store from an earlier schema): its files are
    ///    deleted and a fresh store is created in their place.
    /// 3. Even a clean store fails (the schema itself is unusable — a build-time defect, not
    ///    user data): fall back to an in-memory store so the window still appears instead of
    ///    crash-looping on every launch.
    static func makeContainer(schema: Schema, configuration: ModelConfiguration) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            destroyStore(at: configuration.url)
            if let recreated = try? ModelContainer(for: schema, configurations: [configuration]) {
                return recreated
            }
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // A valid schema always opens in memory; the force is the last resort against a
            // schema so broken the app could not run regardless.
            return try! ModelContainer(for: schema, configurations: [inMemory])
        }
    }

    /// Removes the SQLite store and its write-ahead-log / shared-memory sidecars.
    private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
