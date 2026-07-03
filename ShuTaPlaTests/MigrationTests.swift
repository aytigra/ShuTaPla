//
//  MigrationTests.swift
//  ShuTaPlaTests
//
//  The schema migration must carry an existing store forward without losing the
//  non-derivable rows. Tags and tagging status are filename-derived and repopulate on the
//  next scan, so they are not migrated; everything else (playlists, bookmarks, preferences,
//  file entries, positions, order) survives the lightweight stage.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct MigrationTests {

    /// A unique temp directory plus the store URL inside it; the directory is the
    /// caller's to remove when the test ends.
    private func makeTempStoreURL() -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("default.store"))
    }

    @Test func lightweightMigrationPreservesNonDerivableRows() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileID = UUID()

        // Write a store in the old (V1) schema, then release the container so it flushes.
        do {
            let v1Config = ModelConfiguration(schema: Schema(versionedSchema: SchemaV1.self), url: store)
            let v1 = try ModelContainer(
                for: Schema(versionedSchema: SchemaV1.self),
                configurations: [v1Config]
            )
            let playlist = SchemaV1.Playlist(
                name: "Beach",
                folderBookmark: Data([0x01, 0x02]),
                folderPath: "/Users/test/Beach",
                mediaType: .image,
                sortOrder: 3
            )
            playlist.currentFileID = fileID
            playlist.tagFrequency = ["sunny": 2]
            let file = SchemaV1.PlaylistFile(
                relativePath: "sub/sunset [beach sunny].jpg",
                fileName: "sunset [beach sunny].jpg",
                tags: ["beach", "sunny"],
                taggingStatus: .valid,
                isSkipped: false,
                sortOrder: 7
            )
            file.id = fileID
            file.lastPosition = 12.5
            file.duration = 30
            file.playlist = playlist
            v1.mainContext.insert(playlist)
            v1.mainContext.insert(file)
            try v1.mainContext.save()
        }

        // Reopen the same store through the migration plan into the current (V5) schema,
        // exercising every lightweight stage (V1→V2→V3→V4→V5).
        let schema = Schema(versionedSchema: SchemaV5.self)
        let current = try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: store)]
        )
        let context = current.mainContext

        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        #expect(playlists.count == 1)
        let playlist = try #require(playlists.first)
        #expect(playlist.name == "Beach")
        #expect(playlist.folderBookmark == Data([0x01, 0x02]))
        #expect(playlist.folderPath == "/Users/test/Beach")
        #expect(playlist.mediaType == .image)
        #expect(playlist.sortOrder == 3)
        #expect(playlist.currentFileID == fileID)
        #expect(playlist.tagFrequency == ["sunny": 2])
        #expect(playlist.unfilteredResumeSortOrder == nil)   // new column starts empty

        let files = try context.fetch(FetchDescriptor<PlaylistFile>())
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.id == fileID)
        #expect(file.relativePath == "sub/sunset [beach sunny].jpg")
        #expect(file.fileName == "sunset [beach sunny].jpg")
        #expect(file.isSkipped == false)
        #expect(file.lastPosition == 12.5)
        #expect(file.duration == 30)
        #expect(file.width == nil)                            // new columns start empty
        #expect(file.height == nil)
        #expect(file.fileSizeBytes == nil)
        #expect(file.pixelSize == nil)
        #expect(file.sortOrder == 7)
        #expect(file.playlist?.id == playlist.id)

        // The derived columns exist in the new shape and start empty — a scan repopulates them.
        #expect(file.tags.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ShuTaPla.Tag>()) == 0)
    }

    /// The V2→V3 stage adds the nilable `unfilteredResumeSortOrder` column and leaves every other
    /// row — including the `savedSearches` blob, which already carries each search's
    /// `resumeSortOrder` — untouched. Also confirms the pinned `SchemaV2` shape round-trips.
    @Test func v2ToV3AddsResumeColumnAndPreservesSavedSearches() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let v2Schema = Schema(versionedSchema: SchemaV2.self)
            let v2 = try ModelContainer(for: v2Schema, configurations: [ModelConfiguration(schema: v2Schema, url: store)])
            let playlist = SchemaV2.Playlist(
                name: "Beach", folderBookmark: Data([0x09]), folderPath: "/b", mediaType: .audio, sortOrder: 1
            )
            playlist.savedSearches = [SavedSearch(tags: ["x"], mode: .and, resumeSortOrder: 4)]
            v2.mainContext.insert(playlist)
            try v2.mainContext.save()
        }

        let schema = Schema(versionedSchema: SchemaV3.self)
        let v3 = try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: store)]
        )
        let playlist = try #require(try v3.mainContext.fetch(FetchDescriptor<SchemaV3.Playlist>()).first)
        #expect(playlist.name == "Beach")
        #expect(playlist.sortOrder == 1)
        #expect(playlist.unfilteredResumeSortOrder == nil)        // new column, empty
        #expect(playlist.savedSearches.first?.tags == ["x"])      // blob preserved
        #expect(playlist.savedSearches.first?.resumeSortOrder == 4)
    }

    /// The V3→V4 stage adds the nilable `width`/`height`/`fileSizeBytes` columns and leaves every
    /// other row — including the cached `duration` — untouched. Also confirms the pinned `SchemaV3`
    /// shape round-trips.
    @Test func v3ToV4AddsMetadataColumnsAndPreservesRows() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let v3Schema = Schema(versionedSchema: SchemaV3.self)
            let v3 = try ModelContainer(for: v3Schema, configurations: [ModelConfiguration(schema: v3Schema, url: store)])
            let playlist = SchemaV3.Playlist(
                name: "Beach", folderBookmark: Data([0x09]), folderPath: "/b", mediaType: .video, sortOrder: 1
            )
            let file = SchemaV3.PlaylistFile(relativePath: "a.mp4", fileName: "a.mp4", sortOrder: 2)
            file.duration = 42
            file.lastPosition = 5
            file.playlist = playlist
            v3.mainContext.insert(playlist)
            v3.mainContext.insert(file)
            try v3.mainContext.save()
        }

        let schema = Schema(versionedSchema: SchemaV5.self)
        let current = try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: store)]
        )
        let file = try #require(try current.mainContext.fetch(FetchDescriptor<PlaylistFile>()).first)
        #expect(file.fileName == "a.mp4")
        #expect(file.duration == 42)                              // cached column preserved
        #expect(file.lastPosition == 5)
        #expect(file.sortOrder == 2)
        #expect(file.width == nil)                                // new columns start empty
        #expect(file.height == nil)
        #expect(file.fileSizeBytes == nil)
        #expect(file.pixelSize == nil)
    }

    /// The V4→V5 stage adds the nilable `galleryMinItemWidth` field to the `Playlist.preferences`
    /// composite and leaves every other row — including the rest of that composite — untouched.
    /// Also confirms the pinned `SchemaV4` shape (six-field `preferences`) round-trips.
    @Test func v4ToV5AddsGalleryWidthAndPreservesPreferences() throws {
        let (directory, store) = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let v4Schema = Schema(versionedSchema: SchemaV4.self)
            let v4 = try ModelContainer(for: v4Schema, configurations: [ModelConfiguration(schema: v4Schema, url: store)])
            let playlist = SchemaV4.Playlist(
                name: "Beach", folderBookmark: Data([0x09]), folderPath: "/b", mediaType: .image, sortOrder: 1
            )
            var prefs = LegacySchema.PlaylistPreferences()
            prefs.volume = 0.5
            prefs.slideshowInterval = 7.5
            prefs.viewMode = .gallery
            playlist.preferences = prefs
            v4.mainContext.insert(playlist)
            try v4.mainContext.save()
        }

        let schema = Schema(versionedSchema: SchemaV5.self)
        let current = try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: store)]
        )
        let playlist = try #require(try current.mainContext.fetch(FetchDescriptor<Playlist>()).first)
        #expect(playlist.name == "Beach")
        #expect(playlist.preferences.volume == 0.5)               // composite preserved
        #expect(playlist.preferences.slideshowInterval == 7.5)
        #expect(playlist.preferences.viewMode == .gallery)
        #expect(playlist.preferences.galleryMinItemWidth == nil)  // new field starts empty
    }
}
