//
//  PersistentStoreTests.swift
//  ShuTaPlaTests
//
//  The on-disk container builder must never leave the app stuck on launch: an
//  unreadable store (left by an incompatible schema) is discarded and recreated.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct PersistentStoreTests {

    private var schema: Schema {
        Schema([
            Playlist.self,
            PlaylistFile.self,
            ShuTaPla.Tag.self,
            AppStateModel.self,
            GlobalSettings.self,
        ])
    }

    /// A unique temp directory plus the store URL inside it; the directory is the
    /// caller's to remove when the test ends.
    private func makeTempStoreURL() -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("default.store"))
    }

    /// Documents the hazard the builder guards against: a store file that isn't a valid
    /// SQLite database makes a plain `ModelContainer` initialiser throw — the launch crash
    /// the bare `fatalError` used to turn into a permanent broken state.
    @Test func corruptStoreFailsToOpenNaively() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a database".utf8).write(to: store)

        let configuration = ModelConfiguration(schema: schema, url: store)
        #expect(throws: (any Error).self) {
            _ = try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// The builder discards an unreadable store and returns a working container — the same
    /// corrupt file that throws above launches cleanly here, and the recreated store persists.
    @Test func recreatesUnreadableStore() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a database".utf8).write(to: store)

        let configuration = ModelConfiguration(schema: schema, url: store)
        let container = PersistentStore.makeContainer(schema: schema, configuration: configuration)

        let context = container.mainContext
        context.insert(Playlist(
            name: "Recreated",
            folderBookmark: Data(),
            folderPath: "/tmp/recreated",
            mediaType: .image,
            sortOrder: 0
        ))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 1)
    }

    /// A readable store is opened in place, not wiped — existing rows survive the builder.
    @Test func opensExistingStoreInPlace() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(schema: schema, url: store)

        do {
            let first = PersistentStore.makeContainer(schema: schema, configuration: configuration)
            first.mainContext.insert(Playlist(
                name: "Kept",
                folderBookmark: Data(),
                folderPath: "/tmp/kept",
                mediaType: .image,
                sortOrder: 0
            ))
            try first.mainContext.save()
        }

        let reopened = PersistentStore.makeContainer(schema: schema, configuration: configuration)
        let fetched = try reopened.mainContext.fetch(FetchDescriptor<Playlist>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Kept")
    }
}
