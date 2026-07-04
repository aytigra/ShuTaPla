//
//  TagFrequencyTests.swift
//  ShuTaPlaTests
//
//  The per-playlist `tagFrequency` cache: the authoritative full recompute
//  (`computeTagFrequency`, run by the rescan) and the incremental delta the main-actor edit
//  paths apply instead of re-walking every file. The delta must always land on the same
//  counts the full recompute would — that parity is the property these tests pin.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct TagFrequencyTests {

    /// Holds the container for the whole body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A playlist whose files exercise shared tags, an untagged file, and a skipped file that
    /// carries a tag the cache must ignore.
    private func seededPlaylist(in context: ModelContext) -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        insertFile("a [beach].jpg", tags: ["beach"], status: .valid, order: 0, to: playlist, in: context)
        insertFile("b [beach sunny].jpg", tags: ["beach", "sunny"], status: .valid, order: 1, to: playlist, in: context)
        insertFile("c [sunny].jpg", tags: ["sunny"], status: .valid, order: 2, to: playlist, in: context)
        insertFile("untagged.jpg", status: .untagged, order: 3, to: playlist, in: context)
        insertFile("skip [beach].txt", tags: ["beach"], status: .valid, skipped: true, order: 4, to: playlist, in: context)
        return playlist
    }

    @Test func computeTagFrequencyCountsNonSkippedTags() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = seededPlaylist(in: context)

        // beach: a + b (skip.txt is skipped, excluded); sunny: b + c.
        #expect(context.computeTagFrequency(of: playlist) == ["beach": 2, "sunny": 2])
    }

    @Test func deltaTracksFullRecomputeAcrossEdits() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = seededPlaylist(in: context)
        context.rebuildTagFrequency(of: playlist)

        // Each edit captures the file's contribution, mutates it, applies the delta, and asserts
        // the cache matches an independent full recompute — the property the production edit paths rely on.
        func edit(_ file: PlaylistFile, _ mutate: (PlaylistFile) -> Void) {
            let before = file.tagFrequencyNames
            mutate(file)
            context.applyTagFrequencyDelta(to: playlist, before: before, after: file.tagFrequencyNames)
            #expect(playlist.tagFrequency == context.computeTagFrequency(of: playlist))
        }

        let files = playlist.files.sorted { $0.sortOrder < $1.sortOrder }
        edit(files[0]) { $0.tags = context.tags(named: ["beach", "sunny"]) }  // gain a tag
        edit(files[1]) { $0.tags = context.tags(named: ["sunny"]) }           // lose one of beach's two holders
        edit(files[3]) { $0.tags = context.tags(named: ["night"]) }           // a brand-new tag
        edit(files[0]) { $0.tags = context.tags(named: ["beach"]) }           // drop a sunny holder
        edit(files[2]) { $0.tags = context.tags(named: []) }                  // c drops sunny
        edit(files[1]) { $0.tags = context.tags(named: []) }                  // b drops sunny — its last holder
        #expect(playlist.tagFrequency["sunny"] == nil)                        // zeroed key is gone
        edit(files[4]) { $0.isSkipped = false }                              // un-skip → its beach counts
        edit(files[0]) { $0.tags = [] }                                      // model a delete: subtract its tags
    }
}
