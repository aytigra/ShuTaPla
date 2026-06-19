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
//  Each test draws its container+folder+playlist+appState+router from `playerFixture`
//  or `managerFixture`; the few that drive two channels at once, or no playlist at all,
//  build their setup inline.
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

    /// Everything a routing test drives. The container is held here so its in-memory
    /// context outlives the test body (an orphaned context traps on its next fetch).
    private struct Fixture {
        let container: ModelContainer
        let appState: AppState
        let playlist: Playlist
        let router: HotkeyRouter
        let overlay: MockOverlay
        let closeSpy: CloseSpy
    }

    /// One playlist of `type` playing in Player mode, wired to a router over `overlay`
    /// (default a fresh double). Pass a pre-configured overlay to stage open-overlay or
    /// audio-key-context states before the keys under test arrive.
    private func playerFixture(
        _ type: MediaType, files: [String],
        overlay: MockOverlay = MockOverlay(), textInput: Bool = false
    ) throws -> Fixture {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(files)
        let playlist = makePlaylist(type, folder: folder, files: files, in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(playlist)
        let closeSpy = CloseSpy()
        let router = makeRouter(appState, overlay: overlay, closeSpy: closeSpy, textInput: textInput)
        return Fixture(container: container, appState: appState, playlist: playlist,
                       router: router, overlay: overlay, closeSpy: closeSpy)
    }

    /// One playlist of `type` selected in Manager mode with its filtered files
    /// recomputed. Selection is set directly rather than via `select(_:)`, which
    /// launches an un-awaited re-scan task that would outlive the in-memory container
    /// and trap on a torn-down model. `configure` runs after selection and before the
    /// recompute, for view-mode tweaks (e.g. gallery) that change what it produces.
    private func managerFixture(
        _ type: MediaType, files: [String],
        configure: (AppState, Playlist) -> Void = { _, _ in }
    ) throws -> Fixture {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(files)
        let playlist = makePlaylist(type, folder: folder, files: files, in: context)
        let appState = makeAppState(context)
        appState.mode = .manager
        appState.selectedPlaylist = playlist
        configure(appState, playlist)
        appState.recomputeFilteredFiles()
        let closeSpy = CloseSpy()
        let overlay = MockOverlay()
        let router = makeRouter(appState, overlay: overlay, closeSpy: closeSpy)
        return Fixture(container: container, appState: appState, playlist: playlist,
                       router: router, overlay: overlay, closeSpy: closeSpy)
    }

    /// A fresh overlay double already holding the audio key context.
    private func audioOverlay() -> MockOverlay {
        let overlay = MockOverlay()
        overlay.audioHoldsKeyContext = true
        return overlay
    }

    // MARK: - NSEvent decoding

    @Test func decodesSpecialKeysByKeyCode() {
        #expect(Hotkey(event: keyEvent(keyCode: 49)) == .space)
        #expect(Hotkey(event: keyEvent(keyCode: 53)) == .escape)
        #expect(Hotkey(event: keyEvent(keyCode: 48)) == .tab)
        #expect(Hotkey(event: keyEvent(keyCode: 36)) == .enter)
        #expect(Hotkey(event: keyEvent(keyCode: 76)) == .enter)
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
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.p, rightOption: false))
        #expect(f.appState.coordinator.isSuppressed)
    }

    @Test func spaceEndsSuppressionWhenPauseOverlayShown() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        f.appState.coordinator.suppress()
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.space, rightOption: false))
        #expect(!f.appState.coordinator.isSuppressed)
    }

    @Test func spaceAdvancesVisualWhenPlaying() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let first = f.playlist.currentFileID

        #expect(f.router.route(.space, rightOption: false))
        #expect(f.playlist.currentFileID != first)
    }

    // MARK: - Player: esc priority chain

    @Test func escClosesOverlayBeforeSuppressing() throws {
        let overlay = MockOverlay()
        overlay.isAnyOverlayOpen = true
        let f = try playerFixture(.image, files: ["1.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.escape, rightOption: false))
        #expect(overlay.closeTopmostCalls == 1)
        #expect(!f.appState.coordinator.isSuppressed)   // playback untouched
    }

    @Test func escSuppressesWhenPlaying() throws {
        let f = try playerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.escape, rightOption: false))
        #expect(f.appState.coordinator.isSuppressed)
    }

    @Test func escClosesWindowWhenSuppressed() throws {
        let f = try playerFixture(.image, files: ["1.jpg"])
        f.appState.coordinator.suppress()
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.escape, rightOption: false))
        #expect(f.closeSpy.count == 1)
    }

    // MARK: - Player: overlays, loop, seek

    @Test func tabOpensFilesAndTags() throws {
        let f = try playerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.tab, rightOption: false))
        #expect(f.overlay.openFilesTagsCalls == 1)
    }

    @Test func tabClosesFilesAndTagsWhenOpen() throws {
        let overlay = MockOverlay()
        overlay.isFilesTagsOpen = true
        let f = try playerFixture(.image, files: ["1.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.tab, rightOption: false))
        #expect(overlay.closeFilesTagsCalls == 1)
    }

    @Test func sStopsAndExitsPlayer() throws {
        let f = try playerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.s, rightOption: false))
        #expect(f.appState.mode == .manager)
        #expect(f.appState.coordinator.visualPlaylist == nil)
    }

    @Test func deleteRaisesPlayerConfirmationAndHoldsContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.delete, rightOption: false))
        #expect(f.appState.playerDeleteCandidate != nil)

        // While the confirmation is up the alert owns the keyboard: `[enter]`/`[esc]` pass
        // through to its buttons and every other key is swallowed so transport can't run.
        let arrowRight = keyEvent(keyCode: 124)
        #expect(f.router.handle(arrowRight) == nil)
        let current = f.playlist.currentFileID
        #expect(f.playlist.currentFileID == current)
        #expect(f.appState.playerDeleteCandidate != nil)

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)      // passed to the alert's Cancel button
        #expect(!f.appState.coordinator.isSuppressed)
    }

    @Test func loopTogglesOnAudioChannel() throws {
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: audioOverlay())
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.l, rightOption: false))
        #expect(f.appState.coordinator.isAudioLooping)
        #expect(f.router.route(.l, rightOption: false))
        #expect(!f.appState.coordinator.isAudioLooping)
    }

    @Test func rightOptionArrowSeeksRatherThanAdvances() throws {
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: audioOverlay())
        defer { f.appState.coordinator.shutdown() }
        let current = f.playlist.currentFileID

        #expect(f.router.route(.arrowRight, rightOption: true))
        #expect(f.playlist.currentFileID == current)   // sought, not advanced
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

        let router = makeRouter(appState, overlay: audioOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.arrowRight, rightOption: false))
        #expect(audio.currentFileID != audioBefore)     // audio advanced
        #expect(image.currentFileID == visualBefore)     // visual untouched
    }

    // MARK: - Arrows as overlay controls

    @Test func visualArrowUpOpensFilesAndTags() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let current = f.playlist.currentFileID

        #expect(f.router.route(.arrowUp, rightOption: false))
        #expect(f.overlay.openFilesTagsCalls == 1)
        #expect(f.playlist.currentFileID == current)   // opens the overlay rather than advancing
    }

    @Test func visualArrowUpIsANoOpWhenFilesTagsAlreadyOpen() throws {
        let overlay = MockOverlay()
        overlay.isFilesTagsOpen = true
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowUp, rightOption: false))   // consumed, but neither opens nor closes
        #expect(overlay.openFilesTagsCalls == 0)
        #expect(overlay.closeFilesTagsCalls == 0)
    }

    @Test func visualArrowDownRevealsCompactAudio() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(f.overlay.revealCompactAudioCalls == 1)
    }

    @Test func visualArrowDownClosesFilesAndTagsWhenOpen() throws {
        let overlay = MockOverlay()
        overlay.isFilesTagsOpen = true
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(overlay.closeFilesTagsCalls == 1)
        #expect(overlay.revealCompactAudioCalls == 0)   // closes the overlay rather than revealing audio
    }

    @Test func audioArrowUpClosesTheAudioOverlay() throws {
        let overlay = audioOverlay()
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowUp, rightOption: false))
        #expect(overlay.closeAudioCalls == 1)
    }

    @Test func audioArrowDownExpandsToExtended() throws {
        let overlay = audioOverlay()
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(overlay.expandAudioCalls == 1)
    }

    // MARK: - Text input passthrough

    @Test func textInputSwallowsEverything() throws {
        let f = try playerFixture(.image, files: ["1.jpg"], textInput: true)
        defer { f.appState.coordinator.shutdown() }

        #expect(!f.router.route(.space, rightOption: false))   // not consumed
        #expect(!f.appState.coordinator.isSuppressed)           // no effect
    }

    // MARK: - Manager mode

    @Test func managerArrowsMoveFileSelection() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4", "3.mp4"])
        defer { f.appState.coordinator.shutdown() }

        let files = f.appState.filteredFiles
        #expect(files.count == 3)

        // With nothing selected, the first arrow-down lands on the first row and is consumed.
        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(f.appState.selectedFileIDs == [files[0].id])

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(f.appState.selectedFileIDs == [files[1].id])

        #expect(f.router.route(.arrowUp, rightOption: false))
        #expect(f.appState.selectedFileIDs == [files[0].id])
    }

    @Test func galleryArrowsNavigateInTwoDimensions() throws {
        let names = (1...6).map { "\($0).jpg" }
        let f = try managerFixture(.image, files: names) { _, playlist in
            playlist.preferences.viewMode = .gallery
        }
        f.appState.fileGridColumns = 3
        defer { f.appState.coordinator.shutdown() }

        let files = f.appState.filteredFiles
        #expect(files.count == 6)

        #expect(f.router.route(.arrowRight, rightOption: false))   // nothing selected → first
        #expect(f.appState.selectedFileIDs == [files[0].id])
        #expect(f.router.route(.arrowRight, rightOption: false))   // step right by one
        #expect(f.appState.selectedFileIDs == [files[1].id])
        #expect(f.router.route(.arrowDown, rightOption: false))    // down a row (+3 columns)
        #expect(f.appState.selectedFileIDs == [files[4].id])
        #expect(f.router.route(.arrowUp, rightOption: false))      // up a row (-3 columns)
        #expect(f.appState.selectedFileIDs == [files[1].id])
        #expect(f.router.route(.arrowLeft, rightOption: false))    // step left by one
        #expect(f.appState.selectedFileIDs == [files[0].id])
    }

    @Test func managerEnterPlaysSelectedFile() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg", "3.jpg"])
        defer { f.appState.coordinator.shutdown() }

        let files = f.appState.filteredFiles
        f.appState.selectedFileIDs = [files[1].id]

        #expect(f.router.route(.enter, rightOption: false))
        #expect(f.appState.mode == .player)
        #expect(f.appState.coordinator.visualPlaylist === f.playlist)
        #expect(f.appState.coordinator.visualCurrentFile?.id == files[1].id)
    }

    @Test func managerEnterDoesNothingWithoutSelection() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(!f.router.route(.enter, rightOption: false))   // nothing to play → passes through
        #expect(f.appState.mode == .manager)
    }

    @Test func managerEscIsConsumedButLeavesWindowOpenWhenIdle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = makeAppState(context)
        appState.mode = .manager
        defer { appState.coordinator.shutdown() }

        // Idle Manager `[esc]` is swallowed (no beep) but never closes the window.
        let closeSpy = CloseSpy()
        let router = makeRouter(appState, overlay: MockOverlay(), closeSpy: closeSpy)
        #expect(router.route(.escape, rightOption: false))
        #expect(closeSpy.count == 0)
    }

    @Test func managerDeleteRequestsConfirmationForSelection() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        f.appState.selectedFileIDs = Set(f.appState.filteredFiles.prefix(1).map(\.id))
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.delete, rightOption: false))
        #expect(f.appState.pendingManagerDelete.count == 1)

        // While the confirmation is up the alert owns the keyboard: `[esc]` passes through
        // to its Cancel button (the idle-esc chain doesn't run), and other keys are
        // swallowed so the list can't act behind it.
        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)
        #expect(f.router.handle(keyEvent(keyCode: 49)) == nil)   // [space] swallowed
    }

    @Test func tagRemovalConfirmationPassesEnterEscToTheAlertAndSwallowsTheRest() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        // A file is selected, so an unguarded `[enter]` would otherwise play it.
        f.appState.selectedFileIDs = Set(f.appState.filteredFiles.prefix(1).map(\.id))
        defer { f.appState.coordinator.shutdown() }

        // The alert owns its keys: while it's up, `[enter]`/`[esc]` pass through to it
        // (handled natively by its default/cancel buttons) rather than being routed —
        // so the player is never entered — and every other key is swallowed.
        f.appState.pendingTagRemoval = "beach"

        let enter = keyEvent(keyCode: 36)
        #expect(f.router.handle(enter) === enter)         // passed through to the alert
        #expect(f.appState.mode == .manager)              // not routed to playSelectedFile

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)             // passed through to the alert

        #expect(f.router.handle(keyEvent(keyCode: 49)) == nil)   // [space] swallowed behind it
    }

    @Test func errorAlertHoldsKeyboardContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        // A single-button error alert (here a failed audio strip) is still a modal that owns
        // the keyboard: bare keys must be swallowed and `[enter]`/`[esc]` pass through to it,
        // rather than leaking to playback behind the alert.
        f.appState.audioStripError = "Couldn't remove audio."

        let current = f.playlist.currentFileID
        #expect(f.router.handle(keyEvent(keyCode: 124)) == nil)   // [arrow right] swallowed
        #expect(f.playlist.currentFileID == current)              // not advanced behind it

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                     // passed through to the OK button
    }

    @Test func playlistDeleteConfirmationHoldsKeyboardContext() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        f.appState.selectedFileIDs = Set(f.appState.filteredFiles.prefix(1).map(\.id))
        defer { f.appState.coordinator.shutdown() }

        f.appState.pendingPlaylistDelete = f.playlist

        // [delete] would normally raise a file-trash confirmation; while the playlist-delete
        // dialog owns the keyboard it must be swallowed instead of stacking another modal.
        #expect(f.router.handle(keyEvent(keyCode: 51)) == nil)   // [delete] swallowed
        #expect(f.appState.pendingManagerDelete.isEmpty)

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                    // passed through to the dialog
    }

    @Test func addPlaylistTypeChoiceHoldsKeyboardContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        // The Mixed-folder media-type dialog is a modal that owns the keyboard: bare keys
        // must be swallowed and `[esc]` pass through, rather than leaking to playback behind it.
        f.appState.pendingTypeChoice = PendingPlaylist(
            name: "Mix", bookmark: Data(), folderPath: "/mix",
            scan: ScanResult(files: [], counts: [.video: 1, .image: 1], dominantType: nil)
        )

        let current = f.playlist.currentFileID
        #expect(f.router.handle(keyEvent(keyCode: 124)) == nil)   // [arrow right] swallowed
        #expect(f.playlist.currentFileID == current)              // not advanced behind it

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                     // passed through to the dialog
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
