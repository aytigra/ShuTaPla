//
//  ModelTests.swift
//  ShuTaPlaTests
//
//  Task 1 — data model persistence, singletons, embedded value round-trips,
//  and enum raw-value coding.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct ModelTests {

    /// A fresh in-memory container with the full app schema.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            PlaylistFile.self,
            AppStateModel.self,
            GlobalSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Persistence

    @Test func playlistPersistsWithFiles() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let playlist = Playlist(
            name: "Beach",
            folderBookmark: Data([0x01, 0x02]),
            folderPath: "/Users/test/Beach",
            mediaType: .image,
            sortOrder: 3
        )
        let file = PlaylistFile(
            relativePath: "sunset [beach sunny].jpg",
            fileName: "sunset [beach sunny].jpg",
            tags: ["beach", "sunny"],
            taggingStatus: .valid,
            sortOrder: 0
        )
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Playlist>())
        #expect(fetched.count == 1)
        let stored = try #require(fetched.first)
        #expect(stored.name == "Beach")
        #expect(stored.mediaType == .image)
        #expect(stored.sortOrder == 3)
        #expect(stored.files.count == 1)
        #expect(stored.files.first?.tags == ["beach", "sunny"])
        #expect(stored.files.first?.playlist?.id == stored.id)
    }

    @Test func cascadeDeleteRemovesFiles() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        let file = PlaylistFile(relativePath: "a.mp4", fileName: "a.mp4")
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)
        try context.save()

        context.delete(playlist)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Playlist>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistFile>()).isEmpty)
    }

    // MARK: - Singletons

    @Test func appStateSingletonReturnsSameInstance() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let first = AppStateModel.fetchOrCreate(in: context)
        first.lastManagedVideoPlaylistId = UUID()
        try context.save()

        let second = AppStateModel.fetchOrCreate(in: context)
        #expect(first.persistentModelID == second.persistentModelID)
        #expect(second.lastManagedVideoPlaylistId == first.lastManagedVideoPlaylistId)
        #expect(try context.fetch(FetchDescriptor<AppStateModel>()).count == 1)
    }

    @Test func appStateFetchOrCreateCollapsesDuplicates() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Two rows somehow exist (e.g. a race before the first save). fetchOrCreate
        // returns one and prunes the extras so later reads are deterministic.
        context.insert(AppStateModel())
        context.insert(AppStateModel())
        try context.save()

        _ = AppStateModel.fetchOrCreate(in: context)

        #expect(try context.fetch(FetchDescriptor<AppStateModel>()).count == 1)
    }

    @Test func globalSettingsSingletonReturnsSameInstance() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let first = GlobalSettings.fetchOrCreate(in: context)
        first.defaultSlideshowInterval = 12
        try context.save()

        let second = GlobalSettings.fetchOrCreate(in: context)
        #expect(first.persistentModelID == second.persistentModelID)
        #expect(second.defaultSlideshowInterval == 12)
        #expect(try context.fetch(FetchDescriptor<GlobalSettings>()).count == 1)
    }

    // MARK: - Embedded value round-trips

    @Test func embeddedValuesRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .audio)
        var prefs = PlaylistPreferences()
        prefs.volume = 0.5
        prefs.slideshowEnabled = true
        prefs.slideshowInterval = 7.5
        prefs.imageFitMode = .cover
        prefs.filePositionPersistence = true
        prefs.viewMode = .gallery
        playlist.preferences = prefs
        playlist.filterState = FilterState(selectedTags: ["a", "b"], filterMode: .or, serviceFilter: .untagged)
        playlist.savedSearches = [SavedSearch(tags: ["x", "y"], mode: .and)]
        playlist.tagFrequency = ["beach": 3, "sunny": 1]
        context.insert(playlist)
        try context.save()

        // Re-fetch from a fresh context backed by the same store.
        let context2 = ModelContext(container)
        let stored = try #require(try context2.fetch(FetchDescriptor<Playlist>()).first)
        #expect(stored.preferences.volume == 0.5)
        #expect(stored.preferences.slideshowEnabled == true)
        #expect(stored.preferences.slideshowInterval == 7.5)
        #expect(stored.preferences.imageFitMode == .cover)
        #expect(stored.preferences.filePositionPersistence == true)
        #expect(stored.preferences.viewMode == .gallery)
        #expect(stored.filterState.selectedTags == ["a", "b"])
        #expect(stored.filterState.filterMode == .or)
        #expect(stored.filterState.serviceFilter == .untagged)
        #expect(stored.savedSearches.count == 1)
        #expect(stored.savedSearches.first?.tags == ["x", "y"])
        #expect(stored.tagFrequency["beach"] == 3)
    }

    // MARK: - FilterState coding

    @Test func filterStateRoundTripsServiceFilter() throws {
        let original = FilterState(selectedTags: ["beach"], filterMode: .or, serviceFilter: .skipped)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        #expect(decoded == original)
        #expect(decoded.serviceFilter == .skipped)
    }

    /// A filter persisted before triage filters were stored has no `serviceFilter` key;
    /// it must decode to `nil` rather than failing, so existing playlists keep loading.
    @Test func filterStateDecodesWithoutServiceFilterKey() throws {
        let legacy = #"{"selectedTags":["beach"],"filterMode":"and"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FilterState.self, from: legacy)
        #expect(decoded.selectedTags == ["beach"])
        #expect(decoded.filterMode == .and)
        #expect(decoded.serviceFilter == nil)
    }

    // MARK: - Enum raw values

    @Test(arguments: [
        (MediaType.video, "video"),
        (MediaType.image, "image"),
        (MediaType.audio, "audio"),
    ])
    func mediaTypeRawValues(_ type: MediaType, _ raw: String) {
        #expect(type.rawValue == raw)
        #expect(MediaType(rawValue: raw) == type)
    }

    @Test func allEnumRawValuesDecode() {
        #expect(ImageFitMode(rawValue: "cover") == .cover)
        #expect(ViewMode(rawValue: "gallery") == .gallery)
        #expect(FilterMode(rawValue: "and") == .and)
        #expect(TaggingStatus(rawValue: "invalid") == .invalid)
        #expect(PlaybackState(rawValue: "paused") == .paused)
        #expect(CloudStatus(rawValue: "downloading") == .downloading)
        #expect(ServiceFilter(rawValue: "invalidTagging") == .invalidTagging)
    }

    // MARK: - Enum display properties (one source of truth for the UI)

    @Test(arguments: [
        (MediaType.video, "Video"),
        (MediaType.image, "Image"),
        (MediaType.audio, "Audio"),
    ])
    func mediaTypeDisplayName(_ type: MediaType, _ name: String) {
        #expect(type.displayName == name)
    }

    @Test(arguments: [
        (ServiceFilter.untagged, "tag.slash", "untagged files"),
        (ServiceFilter.invalidTagging, "exclamationmark.triangle", "files with invalid tagging"),
        (ServiceFilter.skipped, "nosign", "skipped files"),
    ])
    func serviceFilterDisplay(_ filter: ServiceFilter, _ image: String, _ label: String) {
        #expect(filter.systemImage == image)
        #expect(filter.label == label)
    }
}
