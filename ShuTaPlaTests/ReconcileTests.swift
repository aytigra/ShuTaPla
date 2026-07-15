//
//  ReconcileTests.swift
//  ShuTaPlaTests
//
//  Projecting a folder scan onto a playlist's files (`ModelContext.reconcile`). The staleness
//  slice: a surviving file whose on-disk size or mtime diverged from its cached baseline has its
//  derived metadata cleared, so the next display re-extracts; a file whose disk facts still match
//  keeps its cache untouched.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct ReconcileTests {

    /// Holds the container for the whole body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A scanned file at `path` carrying the given on-disk staleness facts (untagged, matching type).
    private func scanned(_ path: String, size: Int?, modified: Date?) -> ScannedFile {
        ScannedFile(
            relativePath: path, fileName: path, mediaType: .video, cloudStatus: .local,
            fileSize: size, contentModified: modified, tagNames: [], taggingStatus: .untagged
        )
    }

    /// A playlist holding one video file with a full cached-metadata baseline at `size`/`modified`.
    private func seeded(in context: ModelContext, size: Int, modified: Date) -> (Playlist, PlaylistFile) {
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(playlist)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        file.duration = 10
        file.width = 1920
        file.height = 1080
        file.fileSizeBytes = size
        file.lastModified = modified
        file.fingerprint = "fp"
        try? context.save()
        return (playlist, file)
    }

    @Test func reconcileClearsMetadataOfChangedFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let modified = Date(timeIntervalSince1970: 1)
        let (playlist, file) = seeded(in: context, size: 100, modified: modified)

        // The file grew and was touched on disk — a diverging staleness pair.
        let result = context.reconcile(
            [scanned("a.mp4", size: 200, modified: Date(timeIntervalSince1970: 2))], into: playlist
        )

        #expect(result.changed)              // the invalidation is a change the caller must save
        #expect(file.fileSizeBytes == nil)   // baseline forgotten → next display re-extracts
        #expect(file.lastModified == nil)
        #expect(file.duration == nil)
        #expect(file.fingerprint == nil)
    }

    @Test func reconcileKeepsMetadataOfUnchangedFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let modified = Date(timeIntervalSince1970: 1)
        let (playlist, file) = seeded(in: context, size: 100, modified: modified)

        // Same size, same mtime, same tags → the whole reconcile is a no-op.
        let result = context.reconcile([scanned("a.mp4", size: 100, modified: modified)], into: playlist)

        #expect(!result.changed)
        #expect(file.fileSizeBytes == 100)   // the cache survives untouched
        #expect(file.duration == 10)
        #expect(file.fingerprint == "fp")
    }
}
