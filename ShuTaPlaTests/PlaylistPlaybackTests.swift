//
//  PlaylistPlaybackTests.swift
//  ShuTaPlaTests
//
//  The effective-filter rule, derived store-side on `ModelContext`: `displayFiles` (what file
//  lists show), `playbackFiles` (what playback walks), and `hasPlaybackFiles`. The triage filter,
//  when set, overrides the tag filter for all three; playback always drops skipped files, so the
//  skipped triage filter shows its files but plays none. The derivations fetch with
//  `includePendingChanges: false`, so each scenario saves before deriving.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct PlaylistPlaybackTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @discardableResult
    private func addFile(
        _ name: String, tags: [String] = [], status: TaggingStatus = .untagged,
        skipped: Bool = false, order: Int, to playlist: Playlist, in context: ModelContext
    ) -> PlaylistFile {
        let file = PlaylistFile(
            relativePath: name, fileName: name,
            taggingStatus: status, isSkipped: skipped, sortOrder: order
        )
        file.playlist = playlist
        context.insert(file)
        file.tags = context.tags(named: tags)
        return file
    }

    /// A playlist seeded with a tagged file, an untagged file, an invalid-tagging file, and a
    /// skipped file — one of each triage category plus a normal tagged member — saved so the
    /// store-side derivations can see it.
    private func seededPlaylist(in context: ModelContext) throws -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("tagged.mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("untagged.mp4", status: .untagged, order: 1, to: playlist, in: context)
        addFile("invalid.mp4", status: .invalid, order: 2, to: playlist, in: context)
        addFile("skip.jpg", status: .untagged, skipped: true, order: 3, to: playlist, in: context)
        try context.save()
        return playlist
    }

    @Test func noFilterShowsPlayableExcludesSkipped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        #expect(context.displayFiles(of: playlist).map(\.fileName) == ["tagged.mp4", "untagged.mp4", "invalid.mp4"])
        #expect(context.playbackFiles(of: playlist).map(\.fileName) == ["tagged.mp4", "untagged.mp4", "invalid.mp4"])
        #expect(context.hasPlaybackFiles(in: playlist))
    }

    @Test func tagFilterNarrowsDisplayAndPlayback() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and)
        try context.save()

        #expect(context.displayFiles(of: playlist).map(\.fileName) == ["tagged.mp4"])
        #expect(context.playbackFiles(of: playlist).map(\.fileName) == ["tagged.mp4"])
        #expect(context.hasPlaybackFiles(in: playlist))
    }

    @Test func untaggedServiceFilterDrivesDisplayAndPlayback() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        // A tag filter is set too, to prove the triage filter overrides it.
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and, serviceFilter: .untagged)
        try context.save()

        #expect(context.displayFiles(of: playlist).map(\.fileName) == ["untagged.mp4"])
        #expect(context.playbackFiles(of: playlist).map(\.fileName) == ["untagged.mp4"])
        #expect(context.hasPlaybackFiles(in: playlist))   // untagged files are playable — loop them to fix
    }

    @Test func invalidTaggingServiceFilterPlaybackHonored() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        playlist.filterState.serviceFilter = .invalidTagging
        try context.save()

        #expect(context.playbackFiles(of: playlist).map(\.fileName) == ["invalid.mp4"])
        #expect(context.hasPlaybackFiles(in: playlist))
    }

    @Test func skippedServiceFilterShowsSkippedButPlaysNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)
        playlist.filterState.serviceFilter = .skipped
        try context.save()

        // The file list shows the skipped files for triage, but the playable sequence is
        // empty — the state the Play affordances guard against.
        #expect(context.displayFiles(of: playlist).map(\.fileName) == ["skip.jpg"])
        #expect(context.playbackFiles(of: playlist).isEmpty)
        #expect(!context.hasPlaybackFiles(in: playlist))
    }
}
