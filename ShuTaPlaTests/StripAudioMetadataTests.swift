//
//  StripAudioMetadataTests.swift
//  ShuTaPlaTests
//
//  Remove-audio is an app-initiated in-place content change: `AppState.stripAudio` remuxes the
//  file (dropping audio) and swaps it in, so the cached facts no longer describe the bytes on
//  disk. It must forget that cache and *persist* the clear — otherwise the next
//  `includePendingChanges = false` object fetch refaults the never-saved `nil`s back to the stored
//  values. Driven over a real h264 sample copied into a scoped temp folder; nothing is playing, so
//  the coordinator is never touched and no libmpv engine is created.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct StripAudioMetadataTests {

    /// `test_media/videos`, two levels up from this test file (the repo root).
    private static var videosDirectory: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test_media/videos", directoryHint: .isDirectory)
    }

    private static func sample(prefix: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: nil)
        return try #require(files.first { $0.lastPathComponent.hasPrefix(prefix) })
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func stripAudioForgetsAndPersistsMetadata() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        // A scoped temp folder holding a real, strippable video the operation can remux in place.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaStripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "clip.mp4"
        try FileManager.default.copyItem(at: try Self.sample(prefix: "h264"), to: folder.appending(path: name))
        let bookmark = try BookmarkService.makeBookmark(for: folder)

        let playlist = Playlist(
            name: "V", folderBookmark: bookmark,
            folderPath: folder.path(percentEncoded: false), mediaType: .video
        )
        context.insert(playlist)
        let file = insertFile(name, order: 0, to: playlist, in: context)
        // A full cached baseline that describes the pre-strip bytes.
        file.duration = 10
        file.width = 1920
        file.height = 1080
        file.fileSizeBytes = 999
        file.lastModified = Date(timeIntervalSince1970: 1)
        file.fingerprint = "fp"
        try context.save()

        let appState = AppState(modelContext: context, makeVideoEngine: { try AudioPlaybackEngine() })

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
}
