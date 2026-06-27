//
//  PlaylistPlaybackTests.swift
//  ShuTaPlaTests
//
//  The effective-filter rule on `Playlist`: `displaySequence` (what file lists show),
//  `playbackSequence` (what playback walks), and `hasPlaybackFiles`. The triage filter,
//  when set, overrides the tag filter for all three; playback always drops skipped files,
//  so the skipped triage filter shows its files but plays none.
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
    /// skipped file — one of each triage category plus a normal tagged member.
    private func seededPlaylist(in context: ModelContext) -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .video)
        context.insert(playlist)
        addFile("tagged.mp4", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        addFile("untagged.mp4", status: .untagged, order: 1, to: playlist, in: context)
        addFile("invalid.mp4", status: .invalid, order: 2, to: playlist, in: context)
        addFile("skip.jpg", status: .untagged, skipped: true, order: 3, to: playlist, in: context)
        return playlist
    }

    @Test func noFilterShowsPlayableExcludesSkipped() throws {
        let container = try makeContainer()
        let playlist = seededPlaylist(in: container.mainContext)

        #expect(playlist.displaySequence.map(\.fileName) == ["tagged.mp4", "untagged.mp4", "invalid.mp4"])
        #expect(playlist.playbackSequence.map(\.fileName) == ["tagged.mp4", "untagged.mp4", "invalid.mp4"])
        #expect(playlist.hasPlaybackFiles)
    }

    @Test func tagFilterNarrowsDisplayAndPlayback() throws {
        let container = try makeContainer()
        let playlist = seededPlaylist(in: container.mainContext)
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and)

        #expect(playlist.displaySequence.map(\.fileName) == ["tagged.mp4"])
        #expect(playlist.playbackSequence.map(\.fileName) == ["tagged.mp4"])
        #expect(playlist.hasPlaybackFiles)
    }

    @Test func untaggedServiceFilterDrivesDisplayAndPlayback() throws {
        let container = try makeContainer()
        let playlist = seededPlaylist(in: container.mainContext)
        // A tag filter is set too, to prove the triage filter overrides it.
        playlist.filterState = FilterState(selectedTags: ["beach"], filterMode: .and, serviceFilter: .untagged)

        #expect(playlist.displaySequence.map(\.fileName) == ["untagged.mp4"])
        #expect(playlist.playbackSequence.map(\.fileName) == ["untagged.mp4"])
        #expect(playlist.hasPlaybackFiles)   // untagged files are playable — loop them to fix
    }

    @Test func invalidTaggingServiceFilterPlaybackHonored() throws {
        let container = try makeContainer()
        let playlist = seededPlaylist(in: container.mainContext)
        playlist.filterState.serviceFilter = .invalidTagging

        #expect(playlist.playbackSequence.map(\.fileName) == ["invalid.mp4"])
        #expect(playlist.hasPlaybackFiles)
    }

    @Test func skippedServiceFilterShowsSkippedButPlaysNothing() throws {
        let container = try makeContainer()
        let playlist = seededPlaylist(in: container.mainContext)
        playlist.filterState.serviceFilter = .skipped

        // The file list shows the skipped files for triage, but the playable sequence is
        // empty — the state the Play affordances guard against.
        #expect(playlist.displaySequence.map(\.fileName) == ["skip.jpg"])
        #expect(playlist.playbackSequence.isEmpty)
        #expect(!playlist.hasPlaybackFiles)
    }
}
