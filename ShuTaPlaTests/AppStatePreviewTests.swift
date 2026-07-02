//
//  AppStatePreviewTests.swift
//  ShuTaPlaTests
//
//  The Manager "peek" selection gate: `[space]` opens the preview only for a single selected
//  video/image file, and toggling again closes it. Engine work is covered in `MediaPreviewTests`;
//  here the assertions are on whether the gate opens at all.
//
//  The video slot uses the window-free audio engine (via the factory) so no Vulkan surface is
//  created, and folders are real temp directories with empty placeholder files so the preview's
//  scoped session resolves.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct AppStatePreviewTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaAppStatePreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files { try Data().write(to: url.appending(path: name)) }
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    /// Builds an `AppState` on `context` (window-free video slot) and a managed playlist of `type`
    /// seeded with `files`, returning both. The playlist is set as managed directly (not via a
    /// task-launching path).
    private func makeManaged(
        _ type: MediaType, files: [String], in context: ModelContext
    ) throws -> (app: AppState, playlist: Playlist) {
        let folder = try makeFolder(files)
        let playlist = Playlist(
            name: type.rawValue, folderBookmark: folder.bookmark,
            folderPath: folder.url.path(percentEncoded: false), mediaType: type
        )
        context.insert(playlist)
        for (index, name) in files.enumerated() {
            insertFile(name, order: index, to: playlist, in: context)
        }
        try context.save()
        let app = AppState(modelContext: context, makeVideoEngine: { try AudioPlaybackEngine() })
        app.managedPlaylist = playlist
        return (app, playlist)
    }

    private func fileID(_ name: String, in playlist: Playlist) -> UUID {
        playlist.files.first { $0.fileName == name }!.id
    }

    @Test func singleSelectionOpensAndTogglesClosed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (app, image) = try makeManaged(.image, files: ["1.jpg", "2.jpg"], in: context)
        defer { app.preview.shutdown() }

        app.managerSelection = [fileID("1.jpg", in: image)]
        #expect(app.togglePreviewOfSelection())
        #expect(app.preview.isOpen)

        #expect(app.togglePreviewOfSelection())   // a second toggle closes it
        #expect(!app.preview.isOpen)
    }

    @Test func emptySelectionIsNoOp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (app, _) = try makeManaged(.image, files: ["1.jpg"], in: context)
        defer { app.preview.shutdown() }

        app.managerSelection = []
        #expect(!app.togglePreviewOfSelection())
        #expect(!app.preview.isOpen)
    }

    @Test func multiSelectionIsNoOp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (app, image) = try makeManaged(.image, files: ["1.jpg", "2.jpg"], in: context)
        defer { app.preview.shutdown() }

        app.managerSelection = [fileID("1.jpg", in: image), fileID("2.jpg", in: image)]
        #expect(!app.togglePreviewOfSelection())
        #expect(!app.preview.isOpen)
    }

    @Test func audioSelectionIsNoOp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (app, audio) = try makeManaged(.audio, files: ["a.mp3"], in: context)
        defer { app.preview.shutdown() }

        app.managerSelection = [fileID("a.mp3", in: audio)]
        #expect(!app.togglePreviewOfSelection())   // audio is played inline; no preview
        #expect(!app.preview.isOpen)
    }
}
