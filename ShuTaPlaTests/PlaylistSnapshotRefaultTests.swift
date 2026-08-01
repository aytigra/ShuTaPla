//
//  PlaylistSnapshotRefaultTests.swift
//  ShuTaPlaTests
//
//  The cost model of the snapshot fetch that replaces the sidebar's live `@Query<Playlist>`:
//  a plain fetch must not re-fire the Observation of a `Playlist` instance the app is already
//  holding (which is exactly what a live query does on every store save, storming the gallery),
//  and it must not discard an uncommitted edit on one — the inline rename writes `name` and
//  lets autosave flush it, so a refetch landing in between has to leave the draft standing.
//

import Testing
import Foundation
import Observation
import Synchronization
import SwiftData
@testable import ShuTaPla

@MainActor
struct PlaylistSnapshotRefaultTests {

    /// A fresh in-memory container with the full app schema. The caller holds it for the whole
    /// test body — a context outliving its container traps on its next fetch.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self,
            PlaylistFile.self,
            ShuTaPla.Tag.self,
            AppStateModel.self,
            GlobalSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makePlaylist(_ name: String, sortOrder: Int = 0) -> Playlist {
        Playlist(
            name: name,
            folderBookmark: Data([0x01]),
            folderPath: "/Users/test/\(name)",
            mediaType: .video,
            sortOrder: sortOrder
        )
    }

    /// How many times `playlist`'s observation fires while `body` runs. `withObservationTracking`
    /// fires at most once and is not re-armed, so this is 0 or 1 — enough to tell "woken" from
    /// "untouched". The counter is a `Mutex` because `onChange` is `@Sendable`.
    private func fireCount(observing playlist: Playlist, during body: () -> Void) -> Int {
        let fires = Mutex(0)
        withObservationTracking {
            _ = playlist.name
        } onChange: {
            fires.withLock { $0 += 1 }
        }
        body()
        return fires.withLock { $0 }
    }

    /// The baseline the whole fix rests on: with no `@Query` mounted, saving an unrelated
    /// `PlaylistFile` leaves an untouched `Playlist` instance asleep.
    @Test func unrelatedFileSaveDoesNotFirePlaylistObservation() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let watched = makePlaylist("Watched")
        let other = makePlaylist("Other", sortOrder: 1)
        context.insert(watched)
        context.insert(other)
        let file = PlaylistFile(relativePath: "a.mp4", fileName: "a.mp4", taggingStatus: .valid, sortOrder: 0)
        file.playlist = other
        context.insert(file)
        try context.save()

        let fires = fireCount(observing: watched) {
            file.lastPosition = 12.5
            try? context.save()
        }
        #expect(fires == 0)
    }

    /// The snapshot refetch itself: re-reading every playlist must not refault the instances the
    /// rest of the app is holding, or the replacement would storm on its own signal.
    @Test func refetchingAllPlaylistsDoesNotFireAnUntouchedPlaylistsObservation() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let watched = makePlaylist("Watched")
        context.insert(watched)
        context.insert(makePlaylist("Other", sortOrder: 1))
        try context.save()

        let fires = fireCount(observing: watched) {
            _ = try? context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortOrder)]))
        }
        #expect(fires == 0)
    }

    /// The refetch includes pending changes (the default), so an inline rename still waiting on
    /// autosave survives a snapshot refresh landing on top of it.
    @Test func refetchingAllPlaylistsKeepsAnUnsavedRename() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let playlist = makePlaylist("Before")
        context.insert(playlist)
        try context.save()

        playlist.name = "After"   // uncommitted, as the sidebar's inline rename leaves it
        let fetched = try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortOrder)]))

        #expect(playlist.name == "After")
        #expect(fetched.first?.name == "After")
    }
}
