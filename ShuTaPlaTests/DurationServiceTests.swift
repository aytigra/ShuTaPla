//
//  DurationServiceTests.swift
//  ShuTaPlaTests
//
//  Running-time extraction for the Manager's length indicators. The stateless
//  `extract` resolves a file and reads its length (AVFoundation first, libmpv
//  fallback); the model-facing `duration(for:in:)` serves a cached value without
//  re-reading and writes a freshly extracted one back onto `PlaylistFile.duration`.
//  Real codec-labeled samples in `test_media/videos` back the extraction paths.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@Suite struct DurationServiceTests {

    /// `test_media/videos`, two levels up from this test file (the repo root).
    private static var videosDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "test_media/videos", directoryHint: .isDirectory)
    }

    /// The first sample whose filename starts with `prefix`.
    private static func sample(prefix: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: videosDirectory, includingPropertiesForKeys: nil
        )
        return try #require(
            files.first { $0.lastPathComponent.hasPrefix(prefix) },
            "no sample with prefix \(prefix) in \(videosDirectory.path)"
        )
    }

    /// A fresh in-memory container with the full app schema.
    @MainActor private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Stateless extraction

    @Test func extractReturnsNilForMissingFile() async throws {
        let bookmark = try BookmarkService.makeBookmark(for: Self.videosDirectory)
        let seconds = await DurationService.extract(bookmark: bookmark, relativePath: "does-not-exist.mp4")
        #expect(seconds == nil)
    }

    // h264 takes the AVFoundation path; vp9 falls back to libmpv. The whole chain
    // resolves the bookmark and reports a positive length either way.
    @Test(arguments: ["h264", "vp9"])
    func extractReadsDuration(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)
        let bookmark = try BookmarkService.makeBookmark(for: url.deletingLastPathComponent())
        let seconds = try #require(
            await DurationService.extract(bookmark: bookmark, relativePath: url.lastPathComponent)
        )
        #expect(seconds > 0)
    }

    // MARK: - Model-facing caching

    @MainActor @Test func cachedDurationReturnedWithoutExtraction() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        // An empty bookmark can't resolve, so extraction would yield nil — a non-nil
        // result proves the value came from the model, not a fresh read.
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        let file = PlaylistFile(relativePath: "missing.mp4", fileName: "missing.mp4")
        file.duration = 123.5
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        let seconds = await DurationService().duration(for: file, in: playlist)
        #expect(seconds == 123.5)

        _ = container   // hold the container for the whole test body
    }

    @MainActor @Test func extractsAndCachesOnModel() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let url = try Self.sample(prefix: "h264")
        let dir = url.deletingLastPathComponent()
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "V", folderBookmark: bookmark, folderPath: dir.path, mediaType: .video)
        let file = PlaylistFile(relativePath: url.lastPathComponent, fileName: url.lastPathComponent)
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        let seconds = try #require(await DurationService().duration(for: file, in: playlist))
        #expect(seconds > 0)
        #expect(file.duration == seconds)   // written back onto the model

        _ = container
    }

    // The service reads a container's running time without consulting the playlist's
    // media type, so an audio-scope playlist's files get lengths the same way video does.
    @MainActor @Test func extractsAndCachesForAudioScopePlaylist() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let url = try Self.sample(prefix: "h264")
        let dir = url.deletingLastPathComponent()
        let bookmark = try BookmarkService.makeBookmark(for: dir)
        let playlist = Playlist(name: "A", folderBookmark: bookmark, folderPath: dir.path, mediaType: .audio)
        let file = PlaylistFile(relativePath: url.lastPathComponent, fileName: url.lastPathComponent)
        file.playlist = playlist
        playlist.files = [file]
        context.insert(playlist)

        let seconds = try #require(await DurationService().duration(for: file, in: playlist))
        #expect(seconds > 0)
        #expect(file.duration == seconds)

        _ = container
    }
}
