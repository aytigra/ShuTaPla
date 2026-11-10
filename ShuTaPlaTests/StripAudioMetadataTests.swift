//
//  StripAudioMetadataTests.swift
//  ShuTaPlaTests
//
//  Remove-audio is an app-initiated in-place content change: `AppState.stripAudio` remuxes the
//  file (dropping audio) and swaps it in, so the cached facts no longer describe the bytes on
//  disk. It must forget that cache and *persist* the clear — otherwise the next
//  `includePendingChanges = false` object fetch refaults the never-saved `nil`s back to the stored
//  values. A batch persists each file's clear before the next file's remux. A batch also marks
//  every one of its files busy until that file's own strip ends, so no other file operation
//  reaches a file still queued behind the one in progress. Driven over the h264 fixture copied
//  into a scoped temp folder; nothing is playing, so the coordinator is never touched and no
//  libmpv engine is created.
//

import Testing
import Foundation
import SwiftData
import Observation
@testable import ShuTaPla

@MainActor
struct StripAudioMetadataTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A video playlist over `folder`, holding a real, strippable copy of the h264 fixture for each
    /// of `names` that the operation can remux in place.
    private func makeStrippablePlaylist(
        _ names: [String], in folder: URL, context: ModelContext
    ) throws -> [PlaylistFile] {
        let playlist = Playlist(
            name: "V", folderBookmark: try BookmarkService.makeBookmark(for: folder),
            folderPath: folder.path(percentEncoded: false), mediaType: .video
        )
        context.insert(playlist)
        return try names.enumerated().map { order, name in
            try FileManager.default.copyItem(at: try MediaFixture.h264.url, to: folder.appending(path: name))
            return insertFile(name, order: order, to: playlist, in: context)
        }
    }

    private func makeAppState(_ context: ModelContext) -> AppState {
        AppState(modelContext: context, makeVideoEngine: { try AudioPlaybackEngine() })
    }

    @Test func stripAudioForgetsAndPersistsMetadata() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try #require(try makeStrippablePlaylist(["clip.mp4"], in: folder, context: context).first)
        // A full cached baseline that describes the pre-strip bytes.
        file.duration = 10
        file.width = 1920
        file.height = 1080
        file.fileSizeBytes = 999
        file.lastModified = Date(timeIntervalSince1970: 1)
        file.fingerprint = "fp"
        try context.save()

        let appState = makeAppState(context)

        let message = await appState.stripAudio(from: [file])

        #expect(message == nil)              // the remux + swap succeeded
        #expect(file.duration == nil)        // the stale cache is forgotten…
        #expect(file.width == nil)
        #expect(file.height == nil)
        #expect(file.fileSizeBytes == nil)
        #expect(file.lastModified == nil)
        #expect(file.fingerprint == nil)
        #expect(!context.hasChanges)         // …and persisted, so a later refault can't revive it
    }

    /// Runs `checks` while `strip` runs. A failed check awaits the strip before it ends the test, so
    /// the strip never touches a model after the container is gone (a trap, not a failure).
    private func whileStripping(_ strip: Task<String?, Never>, _ checks: () async throws -> Void) async throws {
        do {
            try await checks()
        } catch {
            _ = await strip.value
            throw error
        }
    }

    @Test func aStrippedFileKeepsItsClearedMetadataWhileTheBatchContinues() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try makeStrippablePlaylist(["a.mp4", "b.mp4"], in: folder, context: context)
        for file in files { file.fingerprint = "fp" }
        try context.save()
        let appState = makeAppState(context)

        let strip = Task { await appState.stripAudio(from: files) }
        try await whileStripping(strip) {
            try await waitUntil { appState.isBusy(files[0]) }
            try await waitUntil { !appState.isBusy(files[0]) }
            try #require(appState.isBusy(files[1]))   // B still remuxes
            // An object fetch that skips pending changes (as `selectedManagerFiles` does) refaults A.
            let id = files[0].id
            var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.id == id })
            descriptor.includePendingChanges = false
            let fetched = try #require(try context.fetch(descriptor).first)
            #expect(fetched.fingerprint == nil)
        }
        #expect(await strip.value == nil)
    }

    @Test func aStripMarksItsWholeBatchBusyUntilEachFileIsDone() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try makeStrippablePlaylist(["a.mp4", "b.mp4"], in: folder, context: context)
        try context.save()
        let appState = makeAppState(context)

        let strip = Task { await appState.stripAudio(from: files) }
        try await whileStripping(strip) { try await waitUntil { appState.isBusy(files[0]) } }
        #expect(appState.isBusy(files[1]))   // queued behind the remux in progress
        #expect(await strip.value == nil)
        #expect(appState.busyFileIDs.isEmpty)
    }

    @Test func aStripLeavesABusyFileAlone() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try makeStrippablePlaylist(["a.mp4"], in: folder, context: context)
        try context.save()
        let appState = makeAppState(context)
        let bytes = try Data(contentsOf: folder.appending(path: "a.mp4"))
        appState.busyFileIDs.insert(files[0].id)

        #expect(await appState.stripAudio(from: files)?.contains("busy") == true)

        #expect(try Data(contentsOf: folder.appending(path: "a.mp4")) == bytes)
        #expect(appState.isBusy(files[0]))
    }

    /// A strip releases each file as its strip ends, so the op's end writes no busy mark: each write
    /// re-renders every visible row. The save after the last release arms the check.
    @Test func aStripWritesNoBusyMarkAfterItsLastRelease() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try makeStrippablePlaylist(["a.mp4"], in: folder, context: context)
        try context.save()
        let probe = BusyWriteProbe()
        let appState = AppState(
            modelContext: context,
            persist: {
                if let appState = probe.appState {
                    withObservationTracking { _ = appState.busyFileIDs } onChange: { probe.fired = true }
                }
                try context.save()
            },
            makeVideoEngine: { try AudioPlaybackEngine() }
        )
        defer { appState.coordinator.shutdown() }
        probe.appState = appState

        #expect(await appState.stripAudio(from: files) == nil)

        #expect(!probe.fired)
    }

    /// A strip over several files refreshes the store-side lists once, not once per file.
    @Test func aStripOverSeveralFilesBumpsTheSequenceVersionOnce() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try makeStrippablePlaylist(["a.mp4", "b.mp4"], in: folder, context: context)
        try context.save()
        let appState = makeAppState(context)
        let before = appState.sequences.version

        #expect(await appState.stripAudio(from: files) == nil)

        #expect(appState.sequences.version == before + 1)
        #expect(!context.hasChanges)
    }
}

/// The `AppState` a test's `persist` reads, and whether a busy-set write fired after it. The
/// `@Sendable` `onChange` sets the flag synchronously on the main actor within the write.
private final class BusyWriteProbe: @unchecked Sendable {
    weak var appState: AppState?
    var fired = false
}
