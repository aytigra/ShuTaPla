//
//  HotkeyRouterTests.swift
//  ShuTaPlaTests
//
//  Task 12 — the priority chain `HotkeyRouter` runs over every key: text-field
//  passthrough, the `[esc]` chain, suppression toggles, and player/audio key-context
//  routing. Decoding `NSEvent`s is checked separately so the routing tests can drive
//  the pure `route(_:rightOption:)` entry point.
//
//  Visual routing uses an image playlist (no libmpv) and audio routing the window-free
//  `AudioPlaybackEngine` (`vo=null`), so nothing in the chain spins up a GL surface.
//  Overlay state is a recording double; key effects are read off the coordinator.
//

import Testing
import Foundation
import SwiftData
import AppKit
@testable import ShuTaPla

@MainActor
@Suite struct HotkeyRouterTests {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaHotkeyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files { try Data().write(to: url.appending(path: name)) }
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    @discardableResult
    private func makePlaylist(
        _ type: MediaType, folder: (url: URL, bookmark: Data),
        files: [String], in context: ModelContext
    ) -> Playlist {
        let playlist = Playlist(
            name: type.rawValue, folderBookmark: folder.bookmark,
            folderPath: folder.url.path(percentEncoded: false), mediaType: type
        )
        context.insert(playlist)
        for (index, name) in files.enumerated() {
            let file = PlaylistFile(
                relativePath: name, fileName: name, tags: [],
                taggingStatus: .untagged, sortOrder: index
            )
            file.playlist = playlist
            context.insert(file)
        }
        return playlist
    }

    /// A recording double for the overlay/key-context seam.
    private final class MockOverlay: HotkeyOverlayContext {
        var isAnyOverlayOpen = false
        var isFilesTagsOpen = false
        var audioHoldsKeyContext = false
        var closeTopmostCalls = 0
        var openFilesTagsCalls = 0
        var closeFilesTagsCalls = 0
        var revealCompactAudioCalls = 0
        var expandAudioCalls = 0
        var closeAudioCalls = 0
        func closeTopmostOverlay() { closeTopmostCalls += 1 }
        func openFilesTags() { openFilesTagsCalls += 1 }
        func closeFilesTags() { closeFilesTagsCalls += 1 }
        func revealCompactAudio() { revealCompactAudioCalls += 1 }
        func expandAudioToExtended() { expandAudioCalls += 1 }
        func closeAudioOverlay() { closeAudioCalls += 1 }
    }

    /// Counts `closeWindow` invocations from a router.
    private final class CloseSpy { var count = 0 }

    private func makeRouter(
        _ appState: AppState, overlay: MockOverlay, closeSpy: CloseSpy,
        textInput: Bool = false
    ) -> HotkeyRouter {
        let router = HotkeyRouter()
        router.appState = appState
        router.overlayContext = overlay
        router.isTextInputActive = { textInput }
        router.closeWindow = { closeSpy.count += 1 }
        return router
    }

    private func makeAppState(_ context: ModelContext) -> AppState {
        AppState(modelContext: context)
    }

    // MARK: - NSEvent decoding

    @Test func decodesSpecialKeysByKeyCode() {
        #expect(Hotkey(event: keyEvent(keyCode: 49)) == .space)
        #expect(Hotkey(event: keyEvent(keyCode: 53)) == .escape)
        #expect(Hotkey(event: keyEvent(keyCode: 48)) == .tab)
        #expect(Hotkey(event: keyEvent(keyCode: 51)) == .delete)
        #expect(Hotkey(event: keyEvent(keyCode: 123)) == .arrowLeft)
        #expect(Hotkey(event: keyEvent(keyCode: 124)) == .arrowRight)
        #expect(Hotkey(event: keyEvent(keyCode: 125)) == .arrowDown)
        #expect(Hotkey(event: keyEvent(keyCode: 126)) == .arrowUp)
    }

    @Test func decodesLettersByCharacter() {
        #expect(Hotkey(event: keyEvent(keyCode: 35, characters: "p")) == .p)
        #expect(Hotkey(event: keyEvent(keyCode: 37, characters: "l")) == .l)
        #expect(Hotkey(event: keyEvent(keyCode: 0, characters: "a")) == nil)
    }

    // MARK: - Player: suppression & space

    @Test func pActivatesSuppression() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg", "2.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        defer { appState.coordinator.shutdown() }

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.p, rightOption: false))
        #expect(appState.coordinator.isSuppressed)
    }

    @Test func spaceEndsSuppressionWhenPauseOverlayShown() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg", "2.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        appState.coordinator.suppress()
        defer { appState.coordinator.shutdown() }

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.space, rightOption: false))
        #expect(!appState.coordinator.isSuppressed)
    }

    @Test func spaceAdvancesVisualWhenPlaying() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg", "2.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        defer { appState.coordinator.shutdown() }
        let first = image.currentFileID

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.space, rightOption: false))
        #expect(image.currentFileID != first)
    }

    // MARK: - Player: esc priority chain

    @Test func escClosesOverlayBeforeSuppressing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        defer { appState.coordinator.shutdown() }

        let overlay = MockOverlay()
        overlay.isAnyOverlayOpen = true
        let router = makeRouter(appState, overlay: overlay, closeSpy: CloseSpy())

        #expect(router.route(.escape, rightOption: false))
        #expect(overlay.closeTopmostCalls == 1)
        #expect(!appState.coordinator.isSuppressed)   // playback untouched
    }

    @Test func escSuppressesWhenPlaying() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        defer { appState.coordinator.shutdown() }

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.escape, rightOption: false))
        #expect(appState.coordinator.isSuppressed)
    }

    @Test func escClosesWindowWhenSuppressed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        appState.coordinator.suppress()
        defer { appState.coordinator.shutdown() }

        let closeSpy = CloseSpy()
        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: closeSpy)
        #expect(router.route(.escape, rightOption: false))
        #expect(closeSpy.count == 1)
    }

    // MARK: - Player: overlays, loop, seek

    @Test func tabOpensFilesAndTags() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        defer { appState.coordinator.shutdown() }

        let overlay = MockOverlay()
        let router = makeRouter(appState, overlay: overlay, closeSpy: CloseSpy())
        #expect(router.route(.tab, rightOption: false))
        #expect(overlay.openFilesTagsCalls == 1)
    }

    @Test func loopTogglesOnAudioChannel() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["a.mp3", "b.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: ["a.mp3", "b.mp3"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(audio)
        defer { appState.coordinator.shutdown() }

        let overlay = MockOverlay()
        overlay.audioHoldsKeyContext = true
        let router = makeRouter(appState, overlay: overlay, closeSpy: CloseSpy())

        #expect(router.route(.l, rightOption: false))
        #expect(appState.coordinator.isAudioLooping)
        #expect(router.route(.l, rightOption: false))
        #expect(!appState.coordinator.isAudioLooping)
    }

    @Test func rightOptionArrowSeeksRatherThanAdvances() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["a.mp3", "b.mp3"])
        let audio = makePlaylist(.audio, folder: folder, files: ["a.mp3", "b.mp3"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(audio)
        defer { appState.coordinator.shutdown() }
        let current = audio.currentFileID

        let overlay = MockOverlay()
        overlay.audioHoldsKeyContext = true
        let router = makeRouter(appState, overlay: overlay, closeSpy: CloseSpy())

        #expect(router.route(.arrowRight, rightOption: true))
        #expect(audio.currentFileID == current)   // sought, not advanced
    }

    // MARK: - Key context routing

    @Test func arrowsRouteToVisualWhenPlayerHoldsContext() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg", "a.mp3", "b.mp3"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg", "2.jpg"], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: ["a.mp3", "b.mp3"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        appState.coordinator.play(audio)
        defer { appState.coordinator.shutdown() }
        let visualBefore = image.currentFileID
        let audioBefore = audio.currentFileID

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.arrowRight, rightOption: false))
        #expect(image.currentFileID != visualBefore)   // visual advanced
        #expect(audio.currentFileID == audioBefore)     // audio untouched
    }

    @Test func arrowsRouteToAudioWhenAudioHoldsContext() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg", "a.mp3", "b.mp3"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg", "2.jpg"], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: ["a.mp3", "b.mp3"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        appState.coordinator.play(audio)
        defer { appState.coordinator.shutdown() }
        let visualBefore = image.currentFileID
        let audioBefore = audio.currentFileID

        let overlay = MockOverlay()
        overlay.audioHoldsKeyContext = true
        let router = makeRouter(appState, overlay: overlay, closeSpy: CloseSpy())
        #expect(router.route(.arrowRight, rightOption: false))
        #expect(audio.currentFileID != audioBefore)     // audio advanced
        #expect(image.currentFileID == visualBefore)     // visual untouched
    }

    // MARK: - Text input passthrough

    @Test func textInputSwallowsEverything() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        defer { appState.coordinator.shutdown() }

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy(), textInput: true)
        #expect(!router.route(.space, rightOption: false))   // not consumed
        #expect(!appState.coordinator.isSuppressed)           // no effect
    }

    // MARK: - Manager mode

    @Test func managerArrowsPassThroughToFileList() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp4"])
        makePlaylist(.video, folder: folder, files: ["1.mp4"], in: context)
        let appState = makeAppState(context)
        appState.mode = .manager
        defer { appState.coordinator.shutdown() }

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(!router.route(.arrowUp, rightOption: false))     // left for the list
        #expect(!router.route(.arrowDown, rightOption: false))
    }

    @Test func managerEscClosesWindowWhenIdle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = makeAppState(context)
        appState.mode = .manager
        defer { appState.coordinator.shutdown() }

        let closeSpy = CloseSpy()
        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: closeSpy)
        #expect(router.route(.escape, rightOption: false))
        #expect(closeSpy.count == 1)
    }

    @Test func managerDeleteRequestsConfirmationForSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.mp4", "2.mp4"])
        let video = makePlaylist(.video, folder: folder, files: ["1.mp4", "2.mp4"], in: context)
        let appState = makeAppState(context)
        appState.mode = .manager
        // Select directly (not via `select(_:)`, which launches an un-awaited re-scan task
        // that would outlive the in-memory container and trap on a torn-down model).
        appState.selectedPlaylist = video
        appState.recomputeFilteredFiles()
        appState.selectedFileIDs = Set(appState.filteredFiles.prefix(1).map(\.id))
        defer { appState.coordinator.shutdown() }

        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.delete, rightOption: false))
        #expect(appState.deleteRequest?.files.count == 1)
    }

    // MARK: - Helpers

    private func keyEvent(keyCode: UInt16, characters: String = " ") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }
}
