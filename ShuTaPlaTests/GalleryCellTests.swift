//
//  GalleryCellTests.swift
//  ShuTaPlaTests
//
//  The gallery tile's `.task` identity. `thumbnailKey` tracks `fingerprint` so an external
//  invalidation (a scan/strip clearing it) re-fires a live cell's generation — the tile
//  regenerates and its badges refresh without waiting for cache eviction or relaunch.
//

import Testing
import Foundation
import SwiftData
import SwiftUI
@testable import ShuTaPla

@MainActor
struct GalleryCellTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeCell(_ file: PlaylistFile, _ playlist: Playlist) -> GalleryCell {
        GalleryCell(
            file: file, playlist: playlist, isSelected: false, isCurrent: false,
            isRenaming: false, isStripping: false, draftName: .constant(""),
            onCommitRename: {}, onCancelRename: {}
        )
    }

    @Test func thumbnailKeyChangesWhenFingerprintCleared() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(playlist)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        file.fingerprint = "fp-1"

        let cell = makeCell(file, playlist)
        let keyed = cell.thumbnailKey
        #expect(keyed.contains("fp-1"))          // the fingerprint is part of the task identity

        file.invalidateMetadata()                // an external clear (scan/strip) drops the fingerprint
        #expect(cell.thumbnailKey != keyed)      // → the key changes, so the cell's .task re-fires
    }

    // The gallery decode is the sole producer of an image's `isHDR` (the list read never decodes a
    // still), and it never gates completeness — so it isn't re-derived by the list producer's saved
    // path. `recordMetadata` must therefore persist it: an unsaved merge is a dirty registered edit
    // that the next `includePendingChanges = false` object fetch (a cloud reconcile, a preview's
    // folder monitor) refaults away, blanking the just-shown HDR badge.
    @Test func recordMetadataPersistsSoObjectFetchKeepsIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "I", folderBookmark: Data(), folderPath: "/i", mediaType: .image)
        context.insert(playlist)
        let file = insertFile("a.heic", order: 0, to: playlist, in: context)
        try context.save()                       // the file is now a stored, non-dirty row (isHDR nil)

        makeCell(file, playlist).recordMetadata(MediaMetadata(isHDR: true))
        #expect(file.isHDR == true)              // the badge fact is on the in-memory model

        // A store-only object fetch refaults any dirty registered object back to its saved values;
        // only a persisted `isHDR` survives it.
        _ = context.files(in: playlist, atRelativePaths: [file.relativePath])
        #expect(file.isHDR == true)              // survived → the merge was saved
    }
}
