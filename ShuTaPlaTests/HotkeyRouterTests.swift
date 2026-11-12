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
        let schema = appTestSchema
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
                relativePath: name, fileName: name,
                taggingStatus: .untagged, sortOrder: index
            )
            file.playlist = playlist
            context.insert(file)
        }
        // The Manager's file lists derive store-side (ignoring pending changes), so the seeded
        // files must be persisted to appear in `managerFiles`.
        try? context.save()
        return playlist
    }

    /// A recording double for the overlay/key-context seam.
    private final class MockOverlay: HotkeyOverlayContext {
        var isAnyOverlayOpen = false
        var isVisualOverlayOpen = false
        var keyContext: KeyContext = .visual
        var closeTopmostCalls = 0
        var openVisualOverlayCalls = 0
        var lastOpenFocusTag: Bool?
        var closeVisualOverlayCalls = 0
        var revealCompactAudioCalls = 0
        var expandAudioCalls = 0
        var closeAudioCalls = 0
        func closeTopmostOverlay() { closeTopmostCalls += 1 }
        func openVisualOverlay(focusTag: Bool) { openVisualOverlayCalls += 1; lastOpenFocusTag = focusTag }
        func closeVisualOverlay() { closeVisualOverlayCalls += 1 }
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

    /// Substitutes the window-free audio engine for the video slot so a `.video` playlist can
    /// go live in the test host without spinning up a GL surface (CLAUDE.md trap class 3).
    private func makeAppState(
        _ context: ModelContext,
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try AudioPlaybackEngine() }
    ) -> AppState {
        AppState(modelContext: context, makeVideoEngine: makeVideoEngine)
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

    /// One playlist of `type` managed in Manager mode. The managed slot is set directly
    /// rather than via `manage(_:)`, which launches an un-awaited re-scan task that would
    /// outlive the in-memory container and trap on a torn-down model. `configure` runs after
    /// the playlist is managed, for view-mode tweaks (e.g. gallery) that change the file list.
    private func managerFixture(
        _ type: MediaType, files: [String],
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try AudioPlaybackEngine() },
        configure: (AppState, Playlist) -> Void = { _, _ in }
    ) throws -> Fixture {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(files)
        let playlist = makePlaylist(type, folder: folder, files: files, in: context)
        let appState = makeAppState(context, makeVideoEngine: makeVideoEngine)
        appState.mode = .manager
        appState.managedPlaylist = playlist
        configure(appState, playlist)
        let closeSpy = CloseSpy()
        let overlay = MockOverlay()
        let router = makeRouter(appState, overlay: overlay, closeSpy: closeSpy)
        return Fixture(container: container, appState: appState, playlist: playlist,
                       router: router, overlay: overlay, closeSpy: closeSpy)
    }

    /// A fresh overlay double already holding the audio key context.
    private func audioOverlay() -> MockOverlay {
        let overlay = MockOverlay()
        overlay.keyContext = .audio
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
        #expect(Hotkey(event: keyEvent(keyCode: 1, characters: "s")) == .s)
        #expect(Hotkey(event: keyEvent(keyCode: 15, characters: "r")) == .r)
        #expect(Hotkey(event: keyEvent(keyCode: 46, characters: "m")) == .m)
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

    @Test func spacePausesVisualWhenPlaying() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let first = f.playlist.currentFileID

        #expect(f.router.route(.space, rightOption: false))
        #expect(f.playlist.playbackState == .paused)   // pauses, never advances
        #expect(f.playlist.currentFileID == first)
    }

    @Test func spacePausesAudioWhenPlaying() throws {
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: audioOverlay())
        defer { f.appState.coordinator.shutdown() }
        let first = f.playlist.currentFileID

        #expect(f.router.route(.space, rightOption: false))
        #expect(f.playlist.playbackState == .paused)   // pauses, never advances
        #expect(f.playlist.currentFileID == first)
    }

    @Test func spaceEndsSuppressionWhenAudioHoldsContext() throws {
        // Suppression is global, so [space] lifts it whichever target holds key context — and
        // only lifts it, leaving the playlist's own play/pause state alone.
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: audioOverlay())
        f.appState.coordinator.suppress()
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.space, rightOption: false))
        #expect(!f.appState.coordinator.isSuppressed)
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

    @Test func tabOpensVisualOverlay() throws {
        let f = try playerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.tab, rightOption: false))
        #expect(f.overlay.openVisualOverlayCalls == 1)
        #expect(f.overlay.lastOpenFocusTag == true)   // [tab] lands the caret in the tag field
    }

    @Test func tabClosesVisualOverlayWhenOpen() throws {
        let overlay = MockOverlay()
        overlay.isVisualOverlayOpen = true
        let f = try playerFixture(.image, files: ["1.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.tab, rightOption: false))
        #expect(overlay.closeVisualOverlayCalls == 1)
    }

    @Test func sStopsAndExitsPlayer() throws {
        let f = try playerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.s, rightOption: false))
        #expect(f.appState.mode == .manager)
        #expect(f.appState.coordinator.liveVisualPlaylist == nil)
    }

    @Test func deleteRaisesPlayerConfirmationAndHoldsContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        let playing = try #require(f.appState.coordinator.visualCurrentFile)
        #expect(f.router.route(.delete, rightOption: false))
        #expect(f.appState.pendingConfirmation?.deleteFiles?.map(\.id) == [playing.id])

        // While the confirmation is up the alert owns the keyboard: `[enter]`/`[esc]` pass
        // through to its buttons and every other key is swallowed so transport can't run.
        let arrowRight = keyEvent(keyCode: 124)
        #expect(f.router.handle(arrowRight) == nil)
        let current = f.playlist.currentFileID
        #expect(f.playlist.currentFileID == current)
        #expect(f.appState.pendingConfirmation?.deleteFiles != nil)

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)      // passed to the alert's Cancel button
        #expect(!f.appState.coordinator.isSuppressed)
    }

    @Test func deleteUnderAudioKeyContextTargetsTheAudioTrack() throws {
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: audioOverlay())
        f.appState.remember(f.playlist)   // occupy the audio channel slot so currentAudioFile resolves
        defer { f.appState.coordinator.shutdown() }

        // With the audio overlay holding key context, `[delete]` targets the focused audio track,
        // not the visual file — like every other contextual key.
        let track = try #require(f.appState.currentAudioFile)
        #expect(f.router.route(.delete, rightOption: false))
        #expect(f.appState.pendingConfirmation?.deleteFiles?.map(\.id) == [track.id])
    }

    @Test func rRaisesRemoveAudioConfirmationForThePlayingVideo() throws {
        let f = try playerFixture(.video, files: ["1.mp4", "2.mp4"])
        defer { f.appState.coordinator.shutdown() }
        let playing = try #require(f.appState.coordinator.visualCurrentFile)

        #expect(f.router.route(.r, rightOption: false))
        #expect(f.appState.pendingConfirmation?.audioStripFiles?.map(\.id) == [playing.id])
    }

    @Test func rTargetsTheVideoEvenWhenAudioHoldsKeyContext() throws {
        // The strip is video-only, so `[r]` always acts on the visual channel — unlike the
        // contextual keys, the audio overlay holding key context doesn't divert it.
        let f = try playerFixture(.video, files: ["1.mp4", "2.mp4"], overlay: audioOverlay())
        defer { f.appState.coordinator.shutdown() }
        let playing = try #require(f.appState.coordinator.visualCurrentFile)

        #expect(f.router.route(.r, rightOption: false))
        #expect(f.appState.pendingConfirmation?.audioStripFiles?.map(\.id) == [playing.id])
    }

    @Test func rIsANoOpWhenAnImageIsOnTheVisualChannel() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(!f.router.route(.r, rightOption: false))   // images have no audio track to strip
        #expect(f.appState.pendingConfirmation == nil)
    }

    @Test func mRaisesTheFolderChooserForThePlayingFile() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let playing = try #require(f.appState.coordinator.visualCurrentFile)

        #expect(f.router.route(.m, rightOption: false))
        #expect(f.appState.folderPick?.moveFileIDs == [playing.id])
    }

    @Test func mUnderAudioKeyContextTargetsTheAudioTrack() throws {
        // Like `[delete]`, `[m]` follows key context: with both channels live and the audio
        // overlay holding it, the focused track moves, not the visual file.
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["1.jpg", "2.jpg", "a.mp3", "b.mp3"])
        let image = makePlaylist(.image, folder: folder, files: ["1.jpg", "2.jpg"], in: context)
        let audio = makePlaylist(.audio, folder: folder, files: ["a.mp3", "b.mp3"], in: context)
        let appState = makeAppState(context)
        appState.mode = .player
        appState.coordinator.play(image)
        appState.coordinator.play(audio)
        appState.remember(audio)   // occupy the audio channel slot so currentAudioFile resolves
        defer { appState.coordinator.shutdown() }
        let track = try #require(appState.currentAudioFile)

        let router = makeRouter(appState, overlay: audioOverlay(), closeSpy: CloseSpy())
        #expect(router.route(.m, rightOption: false))
        #expect(appState.folderPick?.moveFileIDs == [track.id])
    }

    @Test func spaceRestartsAStoppedAudioChannel() throws {
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"], overlay: audioOverlay())
        f.appState.remember(f.playlist)   // the persistent slot survives Stop
        defer { f.appState.coordinator.shutdown() }

        f.appState.coordinator.stop(f.playlist)
        #expect(f.appState.coordinator.liveAudioPlaylist == nil)   // Stop cleared the live channel
        #expect(f.playlist.playbackState == .stopped)

        // `[space]` restarts from the slot — a plain `togglePauseIfActive` would no-op after Stop.
        #expect(f.router.route(.space, rightOption: false))
        #expect(f.appState.coordinator.liveAudioPlaylist === f.playlist)
        #expect(f.playlist.playbackState == .playing)
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

    @Test func visualArrowUpOpensVisualOverlay() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let current = f.playlist.currentFileID

        #expect(f.router.route(.arrowUp, rightOption: false))
        #expect(f.overlay.openVisualOverlayCalls == 1)
        #expect(f.overlay.lastOpenFocusTag == false)   // [arrow up] opens without focusing the tag field
        #expect(f.playlist.currentFileID == current)   // opens the overlay rather than advancing
    }

    @Test func visualArrowUpIsANoOpWhenVisualOverlayAlreadyOpen() throws {
        let overlay = MockOverlay()
        overlay.isVisualOverlayOpen = true
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowUp, rightOption: false))   // consumed, but neither opens nor closes
        #expect(overlay.openVisualOverlayCalls == 0)
        #expect(overlay.closeVisualOverlayCalls == 0)
    }

    @Test func visualArrowDownRevealsCompactAudio() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(f.overlay.revealCompactAudioCalls == 1)
    }

    @Test func visualArrowDownClosesVisualOverlayWhenOpen() throws {
        let overlay = MockOverlay()
        overlay.isVisualOverlayOpen = true
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(overlay.closeVisualOverlayCalls == 1)
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

    @Test func audioOverlayNavigatesWithNoTrackPlaying() throws {
        // The audio overlay can be opened (e.g. from the sidebar's Audio hint) with nothing
        // playing; its [arrow up]/[arrow down] must still close and expand it. Those keys act
        // on the overlay, not the audio channel, so they can't depend on an active playlist.
        let overlay = audioOverlay()
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"], overlay: overlay)
        defer { f.appState.coordinator.shutdown() }
        #expect(f.appState.coordinator.liveAudioPlaylist == nil)

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(overlay.expandAudioCalls == 1)
        #expect(f.router.route(.arrowUp, rightOption: false))
        #expect(overlay.closeAudioCalls == 1)
    }

    // MARK: - Fit-mode cycle ([shift])

    @Test func shiftCyclesTheImagePlayersFitMode() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(f.playlist.preferences.imageFitMode == nil)     // inherits the global default (Fit)
        f.router.cycleImageFitMode()
        #expect(f.playlist.preferences.imageFitMode == .cover)
        f.router.cycleImageFitMode()
        #expect(f.playlist.preferences.imageFitMode == .original)
    }

    @Test func shiftDoesNothingWithoutAVisualImagePlayer() throws {
        // An audio playlist holds no visual channel, so the cycle has no image player to act on.
        let f = try playerFixture(.audio, files: ["a.mp3", "b.mp3"])
        defer { f.appState.coordinator.shutdown() }

        f.router.cycleImageFitMode()
        #expect(f.playlist.preferences.imageFitMode == nil)
    }

    /// A blocking modal swallows bare keys, `[shift]` too.
    @Test func shiftBehindABlockingModalLeavesTheFitModeAlone() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let press = { (down: Bool) in
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
            )!
        }
        _ = f.router.handle(press(true))
        _ = f.router.handle(press(false))
        #expect(f.playlist.preferences.imageFitMode == .cover)   // no modal: the press cycles

        f.appState.report(ErrorNotice(title: "Couldn't move", message: ""))
        _ = f.router.handle(press(true))
        _ = f.router.handle(press(false))
        #expect(f.playlist.preferences.imageFitMode == .cover)
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

        let files = f.appState.managerFiles
        #expect(files.count == 3)

        // With nothing selected, the first arrow-down lands on the first row and is consumed.
        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(f.appState.managerSelection == [files[0].id])

        #expect(f.router.route(.arrowDown, rightOption: false))
        #expect(f.appState.managerSelection == [files[1].id])

        #expect(f.router.route(.arrowUp, rightOption: false))
        #expect(f.appState.managerSelection == [files[0].id])
    }

    @Test func galleryArrowsNavigateInTwoDimensions() throws {
        let names = (1...6).map { "\($0).jpg" }
        let f = try managerFixture(.image, files: names, configure: { _, playlist in
            playlist.preferences.viewMode = .gallery
        })
        f.appState.fileGridColumns = 3
        defer { f.appState.coordinator.shutdown() }

        let files = f.appState.managerFiles
        #expect(files.count == 6)

        #expect(f.router.route(.arrowRight, rightOption: false))   // nothing selected → first
        #expect(f.appState.managerSelection == [files[0].id])
        #expect(f.router.route(.arrowRight, rightOption: false))   // step right by one
        #expect(f.appState.managerSelection == [files[1].id])
        #expect(f.router.route(.arrowDown, rightOption: false))    // down a row (+3 columns)
        #expect(f.appState.managerSelection == [files[4].id])
        #expect(f.router.route(.arrowUp, rightOption: false))      // up a row (-3 columns)
        #expect(f.appState.managerSelection == [files[1].id])
        #expect(f.router.route(.arrowLeft, rightOption: false))    // step left by one
        #expect(f.appState.managerSelection == [files[0].id])
    }

    @Test func managerEnterPlaysSelectedFile() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg", "3.jpg"])
        defer { f.appState.coordinator.shutdown() }

        let files = f.appState.managerFiles
        f.appState.managerSelection = [files[1].id]

        #expect(f.router.route(.enter, rightOption: false))
        #expect(f.appState.mode == .player)
        #expect(f.appState.coordinator.liveVisualPlaylist === f.playlist)
        #expect(f.appState.coordinator.visualCurrentFile?.id == files[1].id)
    }

    @Test func managerSpaceOpensPreviewForSingleSelection() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.preview.shutdown(); f.appState.coordinator.shutdown() }

        let files = f.appState.managerFiles
        f.appState.managerSelection = [files[0].id]

        #expect(f.router.route(.space, rightOption: false))
        #expect(f.appState.preview.isOpen)
    }

    @Test func managerSpaceIsANoOpWithoutASingleSelection() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        // Nothing selected → the preview never opens and the key isn't consumed.
        #expect(!f.router.route(.space, rightOption: false))
        #expect(!f.appState.preview.isOpen)
    }

    @Test func openPreviewOwnsTheKeyboardAndClosesOnSpaceOrEsc() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.preview.shutdown(); f.appState.coordinator.shutdown() }

        let files = f.appState.managerFiles
        f.appState.managerSelection = [files[0].id]
        f.router.route(.space, rightOption: false)
        #expect(f.appState.preview.isOpen)

        // While the lightbox is open every other key is swallowed and can't reach the list.
        #expect(f.router.handle(keyEvent(keyCode: 124)) == nil)   // [arrow right] swallowed
        #expect(f.appState.managerSelection == [files[0].id])     // selection didn't move
        #expect(f.appState.preview.isOpen)

        // [esc] closes it (as does a second [space]).
        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) == nil)
        #expect(!f.appState.preview.isOpen)
    }

    @Test func openVideoPreviewSeeksOnArrowKeysAndStaysOpen() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"],
                                   makeVideoEngine: { try RecordingSeekEngine() })
        defer { f.appState.preview.shutdown(); f.appState.coordinator.shutdown() }

        f.appState.managerSelection = [f.appState.managerFiles[0].id]
        f.router.route(.space, rightOption: false)
        #expect(f.appState.preview.isOpen)
        let engine = try #require(f.appState.preview.videoEngine as? RecordingSeekEngine)

        // Arrow keys seek the previewed video ∓3 s and are consumed; the lightbox stays open.
        #expect(f.router.handle(keyEvent(keyCode: 123)) == nil)   // [arrow left]  → −3 s
        #expect(f.router.handle(keyEvent(keyCode: 124)) == nil)   // [arrow right] → +3 s
        #expect(engine.seekByDeltas == [-3, 3])
        #expect(f.appState.preview.isOpen)
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
        defer { f.appState.coordinator.shutdown() }
        let selected = try #require(f.appState.managerFiles.first)
        f.appState.managerSelection = [selected.id]

        #expect(f.router.route(.delete, rightOption: false))
        #expect(f.appState.pendingConfirmation?.deleteFiles?.map(\.id) == [selected.id])

        // While the confirmation is up the alert owns the keyboard: `[esc]` passes through
        // to its Cancel button (the idle-esc chain doesn't run), and other keys are
        // swallowed so the list can't act behind it.
        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)
        #expect(f.router.handle(keyEvent(keyCode: 49)) == nil)   // [space] swallowed
    }

    @Test func managerMRaisesTheFolderChooserForTheSelection() throws {
        let f = try managerFixture(.image, files: ["1.jpg", "2.jpg", "3.jpg"])
        defer { f.appState.coordinator.shutdown() }
        let selected = f.appState.managerFiles.prefix(2).map(\.id)
        f.appState.managerSelection = Set(selected)

        #expect(f.router.route(.m, rightOption: false))
        #expect(Set(f.appState.folderPick?.moveFileIDs ?? []) == Set(selected))
    }

    @Test func managerMIsANoOpWithoutSelection() throws {
        let f = try managerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }

        #expect(!f.router.route(.m, rightOption: false))
        #expect(f.appState.folderPick == nil)
    }

    @Test func managerRRequestsRemoveAudioForTheSelection() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        defer { f.appState.coordinator.shutdown() }
        let selected = try #require(f.appState.managerFiles.first)
        f.appState.managerSelection = [selected.id]

        #expect(f.router.route(.r, rightOption: false))
        #expect(f.appState.pendingConfirmation?.audioStripFiles?.map(\.id) == [selected.id])
    }

    @Test func managerRIsANoOpOnAnImagePlaylist() throws {
        let f = try managerFixture(.image, files: ["1.jpg"])
        defer { f.appState.coordinator.shutdown() }
        f.appState.managerSelection = Set(f.appState.managerFiles.map(\.id))

        #expect(!f.router.route(.r, rightOption: false))   // images have no audio track to strip
        #expect(f.appState.pendingConfirmation == nil)
    }

    @Test func tagRemovalConfirmationPassesEnterEscToTheAlertAndSwallowsTheRest() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        // A file is selected, so an unguarded `[enter]` would otherwise play it.
        f.appState.managerSelection = Set(f.appState.managerFiles.prefix(1).map(\.id))
        defer { f.appState.coordinator.shutdown() }

        // The alert owns its keys: while it's up, `[enter]`/`[esc]` pass through to it
        // (handled natively by its default/cancel buttons) rather than being routed —
        // so the player is never entered — and every other key is swallowed.
        f.appState.requestTagRemoval("beach")

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
        // rather than leaking to playback behind the alert. One channel carries every such
        // report — a refused save, a failed tag edit — so this holds for all of them, and it is
        // why none of them may be raised from a view's own `@State`.
        f.appState.report(ErrorNotice(title: "Couldn't remove audio", message: "Couldn't remove audio."))

        let current = f.playlist.currentFileID
        #expect(f.router.handle(keyEvent(keyCode: 124)) == nil)   // [arrow right] swallowed
        #expect(f.playlist.currentFileID == current)              // not advanced behind it

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                     // passed through to the OK button
    }

    @Test func quitWaitAlertHoldsKeyboardContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        f.appState.replyToTerminate = { _ in }
        f.appState.isWaitingToQuit = true

        let current = f.playlist.currentFileID
        #expect(f.router.handle(keyEvent(keyCode: 124)) == nil)   // [arrow right] swallowed
        #expect(f.playlist.currentFileID == current)              // not advanced behind it

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                     // passed through to Cancel Quitting
    }

    /// A closing alert is still a sheet on the window, and an alert raised under it is dropped.
    /// While the window has a sheet, no key raises a modal.
    @Test func aSheetStillOnTheWindowHoldsKeyboardContext() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        f.appState.managerSelection = Set(f.appState.managerFiles.prefix(1).map(\.id))
        defer { f.appState.coordinator.shutdown() }
        f.appState.windowHasSheet = true

        #expect(f.router.handle(keyEvent(keyCode: 51)) == nil)            // [delete] swallowed
        #expect(f.appState.pendingConfirmation == nil)
        #expect(f.router.handle(keyEvent(keyCode: 46, characters: "m")) == nil)   // [m] swallowed
        #expect(f.appState.folderPick == nil)

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                               // passed through to the sheet
    }

    @Test func anOpenFolderChooserPassesEveryKeyThrough() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        f.appState.folderPick = .addPlaylist

        // A key that reaches the app while the chooser is up belongs to the chooser.
        let s = keyEvent(keyCode: 1, characters: "s")
        #expect(f.router.handle(s) === s)
        #expect(f.appState.mode == .player)                          // not stopped behind it
        #expect(f.appState.coordinator.liveVisualPlaylist != nil)
        let delete = keyEvent(keyCode: 51)
        #expect(f.router.handle(delete) === delete)
        #expect(f.appState.pendingConfirmation == nil)               // no trash alert behind it
    }

    /// A chooser queued behind a report holds the keyboard like any queued modal: the report on
    /// screen gets `[esc]`, and nothing acts behind it.
    @Test func aQueuedFolderChooserHoldsKeyboardContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }
        f.appState.report(ErrorNotice(title: "Couldn't move", message: "1 file(s) couldn't be moved."))
        f.appState.folderPick = .addPlaylist

        #expect(f.router.handle(keyEvent(keyCode: 1, characters: "s")) == nil)   // [s] swallowed
        #expect(f.appState.mode == .player)
        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)
    }

    @Test func playlistDeleteConfirmationHoldsKeyboardContext() throws {
        let f = try managerFixture(.video, files: ["1.mp4", "2.mp4"])
        f.appState.managerSelection = Set(f.appState.managerFiles.prefix(1).map(\.id))
        defer { f.appState.coordinator.shutdown() }

        f.appState.requestPlaylistDelete(f.playlist)

        // [delete] would normally raise a file-trash confirmation; while the playlist-delete
        // dialog owns the keyboard it must be swallowed instead of stacking another modal.
        #expect(f.router.handle(keyEvent(keyCode: 51)) == nil)   // [delete] swallowed
        #expect(f.appState.pendingConfirmation?.playlistToDelete === f.playlist)

        let esc = keyEvent(keyCode: 53)
        #expect(f.router.handle(esc) === esc)                    // passed through to the dialog
    }

    @Test func addPlaylistTypeChoiceHoldsKeyboardContext() throws {
        let f = try playerFixture(.image, files: ["1.jpg", "2.jpg"])
        defer { f.appState.coordinator.shutdown() }

        // The Mixed-folder media-type dialog is a modal that owns the keyboard: bare keys
        // must be swallowed and `[esc]` pass through, rather than leaking to playback behind it.
        f.appState.pendingTypeChoice = ScannedFolder(
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
