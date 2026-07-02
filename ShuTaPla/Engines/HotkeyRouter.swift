//
//  HotkeyRouter.swift
//  ShuTaPla
//
//  The single owner of keyboard input. One app-wide `NSEvent` local monitor feeds
//  every key through one priority chain: a focused text field swallows everything,
//  then `[esc]` runs its context-dependent chain, then the remaining player keys go
//  to whichever target holds *key context* — the active video/image player by
//  default, or the audio overlay once it is fully revealed.
//
//  Returning `nil` from the monitor consumes the event (so `[esc]` never reaches the
//  system's exit-from-fullscreen, and player keys never leak to controls); returning
//  the event lets it continue to normal dispatch (so a focused text field still types).
//
//  Overlay state lives in an `OverlayManager`; the audio key-context comes from the
//  audio overlay (Task 15). The router reads both through `HotkeyOverlayContext`, falling
//  back to `NoOverlayContext` when none is set, so the player/manager transport keys all
//  work and the audio overlay branches stay inert until that overlay lands.
//

import AppKit

/// Which surface currently receives the contextual keys (arrows, `[space]`, `[l]`, seek,
/// `[delete]`): the Visual Channel or the Audio Overlay.
enum KeyContext {
    case visual, audio
}

/// The overlay/key-context state and actions the router consults. The player shell
/// supplies `NoOverlayContext`; Tasks 13–15 swap in the real `OverlayManager`.
@MainActor
protocol HotkeyOverlayContext: AnyObject {
    /// A closable overlay is open (Visual Overlay, Playlists, or a hotkey-opened audio
    /// overlay) — `[esc]` closes the topmost one before touching playback.
    var isAnyOverlayOpen: Bool { get }
    /// The Visual Overlay is open, so `[arrow up]`/`[tab]` is a no-op and
    /// `[arrow down]` closes it rather than revealing audio.
    var isVisualOverlayOpen: Bool { get }
    /// Which surface owns key context. `.audio` once the audio overlay is fully revealed —
    /// arrows, `[space]`, `[l]`, seek, and `[delete]` then act on the audio playlist;
    /// otherwise `.visual`.
    var keyContext: KeyContext { get }

    func closeTopmostOverlay()
    func openVisualOverlay()
    func closeVisualOverlay()
    func revealCompactAudio()
    func expandAudioToExtended()
    func closeAudioOverlay()
}

/// The player-shell default: no overlays, player always holds key context.
@MainActor
final class NoOverlayContext: HotkeyOverlayContext {
    var isAnyOverlayOpen: Bool { false }
    var isVisualOverlayOpen: Bool { false }
    var keyContext: KeyContext { .visual }
    func closeTopmostOverlay() {}
    func openVisualOverlay() {}
    func closeVisualOverlay() {}
    func revealCompactAudio() {}
    func expandAudioToExtended() {}
    func closeAudioOverlay() {}
}

/// The keys the router acts on, decoded from an `NSEvent` once so the routing logic
/// is a pure function of key + right-option and is unit-testable without AppKit.
enum Hotkey: Equatable {
    case space, escape, tab, enter, p, l, s, r, delete
    case arrowUp, arrowDown, arrowLeft, arrowRight

    /// Decodes a key-down event, or `nil` if it isn't a key the router handles.
    /// Special keys go by `keyCode` (layout-independent); letters by character so
    /// they follow the user's layout.
    init?(event: NSEvent) {
        if let special = Hotkey.special(forKeyCode: event.keyCode) {
            self = special
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p": self = .p
        case "l": self = .l
        case "s": self = .s
        case "r": self = .r
        default: return nil
        }
    }

    private static func special(forKeyCode code: UInt16) -> Hotkey? {
        switch code {
        case 49: return .space
        case 53: return .escape
        case 48: return .tab
        case 36, 76: return .enter          // return / keypad enter
        case 51, 117: return .delete        // delete / forward-delete
        case 123: return .arrowLeft
        case 124: return .arrowRight
        case 125: return .arrowDown
        case 126: return .arrowUp
        default: return nil
        }
    }
}

@MainActor
final class HotkeyRouter {

    /// The runtime state the router drives. Weak: `AppState` owns the session and the
    /// router only acts on it while the window is up.
    weak var appState: AppState?

    /// The app's `OverlayManager` once installed; `NoOverlayContext` before then.
    var overlayContext: HotkeyOverlayContext = NoOverlayContext()

    /// Whether a focused text field should swallow keys. Injectable so tests drive the
    /// chain without a real key window.
    var isTextInputActive: @MainActor () -> Bool = HotkeyRouter.defaultTextInputCheck

    /// Closes the window (the suppressed/Manager `[esc]` terminus). Injectable for tests.
    var closeWindow: @MainActor () -> Void = { NSApp.keyWindow?.performClose(nil) }

    private var monitor: Any?

    /// Right Option held, tracked from `.flagsChanged` (keyCode 61) so `[right option]+arrow`
    /// can be told apart from a plain arrow without a device-dependent modifier mask.
    private var rightOptionDown = false

    /// Whether a Shift key is currently held, tracked from `.flagsChanged` (keyCodes 56/60)
    /// so the fit-mode cycle fires once on the press edge rather than repeatedly.
    private var shiftDown = false

    private var coordinator: PlaybackCoordinator? { appState?.coordinator }

    /// Whether a modal confirmation or error alert is up and owns the keyboard. Covers the
    /// confirmation dialogs (Manager trash, remove-audio, player trash, playlist tag removal,
    /// add-playlist media-type choice) and the single-button error alerts that report a failed
    /// operation — for any of them the app-wide monitor must pass `[enter]`/`[esc]` through and
    /// swallow the rest, or bare keys leak to playback / the file list behind the modal.
    private var hasBlockingConfirmation: Bool {
        guard let appState else { return false }
        return appState.pendingConfirmation != nil
            || appState.confirmationError != nil
            || appState.playerRenameError != nil
            || appState.audioRenameError != nil
            || appState.pendingTypeChoice != nil
            || appState.addPlaylistError != nil
            || appState.saveError != nil
    }

    // MARK: - Monitor lifecycle

    /// Installs the app-wide key monitor. Idempotent.
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // When the router is gone, let the event flow normally; otherwise the
            // router's decision stands — `nil` consumes (and suppresses the beep),
            // a returned event passes through. (A `?? event` fallback here would
            // resurrect every consumed event and beep on every handled key.)
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: - Event handling

    /// Maps an `NSEvent` to a routing decision: `nil` consumes it, the event lets it
    /// pass through. Also tracks the Right Option modifier from `.flagsChanged`.
    func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            if event.keyCode == 61 { rightOptionDown = event.modifierFlags.contains(.option) }
            // `[shift]` (left 56 / right 60) cycles the image player's fit mode, once on the
            // press edge. A focused text field types a capital instead, so it's exempt.
            if event.keyCode == 56 || event.keyCode == 60 {
                let down = event.modifierFlags.contains(.shift)
                if down, !shiftDown, !isTextInputActive() { cycleImageFitMode() }
                shiftDown = down
            }
            return event
        }
        guard event.type == .keyDown else { return event }

        // Leave Command/Control combinations to the menu system and the responder
        // chain (Cmd+Q, Cmd+, …); the router only owns bare keys (and Right Option).
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return event
        }

        // A focused text field types; the router never intercepts it.
        if isTextInputActive() { return event }

        // A confirmation dialog is a modal that owns `[enter]`/`[esc]` natively. Pass
        // those through so its own default/cancel buttons fire instantly; consuming them
        // here would both route them elsewhere (e.g. `[enter]` to the file list) and lag
        // the dismissal behind the dialog's event-tracking loop. Other keys are swallowed
        // so nothing acts behind it.
        if hasBlockingConfirmation {
            switch Hotkey(event: event) {
            case .enter, .escape: return event
            default: return nil
            }
        }

        if let key = Hotkey(event: event), route(key, rightOption: rightOptionDown) {
            return nil
        }

        // In the immersive fullscreen player there is nothing for a stray key to do
        // and nowhere for it to go, so swallow it rather than let it ring the bell.
        if appState?.mode == .player { return nil }
        return event
    }

    // MARK: - Routing

    /// Routes a decoded key. Returns whether it was consumed. The text-input guard runs
    /// first (focused field swallows everything), then the active mode decides.
    @discardableResult
    func route(_ key: Hotkey, rightOption: Bool) -> Bool {
        guard let appState else { return false }
        if isTextInputActive() { return false }
        switch appState.mode {
        case .player: return routePlayer(key, rightOption: rightOption)
        case .manager: return routeManager(key, rightOption: rightOption)
        case .welcome: return false
        }
    }

    /// `[shift]` cycles the live image player's fit mode. A no-op unless an image playlist
    /// holds the visual channel.
    func cycleImageFitMode() {
        guard let coordinator = appState?.coordinator,
              let visual = coordinator.liveVisualPlaylist,
              visual.mediaType == .image else { return }
        coordinator.cycleImageFitMode(visual)
    }

    private func routePlayer(_ key: Hotkey, rightOption: Bool) -> Bool {
        guard let appState, let coordinator else { return false }

        // `[esc]` — its priority chain runs regardless of which target holds key context.
        if key == .escape {
            if overlayContext.isAnyOverlayOpen { overlayContext.closeTopmostOverlay(); return true }
            if !coordinator.isSuppressed { coordinator.suppress(); return true }
            closeWindow()
            return true
        }

        // `[p]` toggles suppression globally (and ends it from the pause overlay).
        if key == .p {
            coordinator.isSuppressed ? coordinator.unsuppress() : coordinator.suppress()
            return true
        }

        // `[space]` while suppressed lifts suppression globally — whichever target holds key
        // context, and without disturbing any playlist's own pause state. Only when not
        // suppressed does it fall through to the context's pause toggle.
        if key == .space, coordinator.isSuppressed {
            coordinator.unsuppress()
            return true
        }

        // `[s]` stops the visual playlist and returns to Manager.
        if key == .s {
            appState.stopAndExitPlayer()
            return true
        }

        // `[r]` raises the remove-audio confirmation for the playing video. The strip is
        // video-only, so — unlike the contextual keys — it always targets the visual channel:
        // an audio track has nothing to strip. A no-op when an image or audio file is on it.
        if key == .r {
            return appState.requestStripPlayingFile()
        }

        // `[delete]` raises the trash confirmation for the playing file — the focused track when
        // the audio overlay holds key context, otherwise the visual channel's file. Every other
        // contextual key already respects key context, so `[delete]` does too.
        if key == .delete {
            return overlayContext.keyContext == .audio
                ? appState.requestDeletePlayingAudioFile()
                : appState.requestDeletePlayingFile()
        }

        return overlayContext.keyContext == .audio
            ? routeAudio(key, rightOption: rightOption)
            : routeVisual(key, rightOption: rightOption)
    }

    private func routeVisual(_ key: Hotkey, rightOption: Bool) -> Bool {
        guard let coordinator, let visual = coordinator.liveVisualPlaylist else { return false }

        if rightOption, key == .arrowLeft { coordinator.seek(visual, by: -3); return true }
        if rightOption, key == .arrowRight { coordinator.seek(visual, by: 3); return true }

        switch key {
        case .space: coordinator.togglePauseIfActive(visual)
        case .arrowRight: coordinator.next(visual)
        case .arrowLeft: coordinator.previous(visual)
        case .tab:
            // Toggle: opens the Visual Overlay, or closes it however it was opened.
            overlayContext.isVisualOverlayOpen ? overlayContext.closeVisualOverlay() : overlayContext.openVisualOverlay()
        case .arrowUp:
            // Opens the Visual Overlay, but never closes it (that's Tab / Esc / Down).
            if !overlayContext.isVisualOverlayOpen { overlayContext.openVisualOverlay() }
        case .arrowDown:
            if overlayContext.isVisualOverlayOpen { overlayContext.closeVisualOverlay() }
            else { overlayContext.revealCompactAudio() }
        case .l: coordinator.toggleLoop(visual)
        default: return false
        }
        return true
    }

    private func routeAudio(_ key: Hotkey, rightOption: Bool) -> Bool {
        // Overlay navigation acts on the overlay, not the audio channel, so it works whether
        // or not a track is playing — the overlay can be opened (and must be closeable) while
        // the channel is idle.
        switch key {
        case .arrowUp: overlayContext.closeAudioOverlay(); return true
        case .arrowDown: overlayContext.expandAudioToExtended(); return true
        default: break
        }

        // `[space]` drives the channel's transport off the persistent slot, so — like the
        // overlay's Play button — it can restart a Stopped audio playlist (which `togglePauseIfActive`
        // can't, since Stop clears `liveAudioPlaylist`). The slot is the live channel while it plays;
        // it outlives Stop, falling back to the live channel only if no slot is loaded.
        if key == .space, let coordinator,
           let target = appState?.audioChannelPlaylist ?? coordinator.liveAudioPlaylist {
            coordinator.playOrTogglePause(target)
            return true
        }

        // Seek, advance, and loop need an active audio playlist.
        guard let coordinator, let audio = coordinator.liveAudioPlaylist else { return false }

        if rightOption, key == .arrowLeft { coordinator.seek(audio, by: -3); return true }
        if rightOption, key == .arrowRight { coordinator.seek(audio, by: 3); return true }

        switch key {
        case .arrowRight: coordinator.next(audio)
        case .arrowLeft: coordinator.previous(audio)
        case .l: coordinator.toggleLoop(audio)
        default: return false
        }
        return true
    }

    private func routeManager(_ key: Hotkey, rightOption: Bool) -> Bool {
        // A top-edge-hover audio overlay can take key context in Manager too; otherwise
        // arrows are left for the file list.
        if overlayContext.keyContext == .audio {
            return routeAudio(key, rightOption: rightOption)
        }
        switch key {
        case .escape:
            // Cancel an in-progress operation (rename / tagging) if there is one;
            // otherwise swallow the key. Manager `[esc]` never closes the window.
            appState?.cancelInProgressOperation()
            return true
        case .enter:
            // Play the selected file (the text-input guard upstream means this only fires
            // when no field is focused, so a rename's Return still commits the field).
            return appState?.playSelectedFile() ?? false
        case .delete:
            return appState?.requestDeleteSelectedFiles() ?? false
        case .arrowUp:
            return appState?.moveFileSelection(.up) ?? false
        case .arrowDown:
            return appState?.moveFileSelection(.down) ?? false
        case .arrowLeft:
            return appState?.moveFileSelection(.left) ?? false
        case .arrowRight:
            return appState?.moveFileSelection(.right) ?? false
        default:
            return false        // the rest fall through to the list
        }
    }

    // MARK: - Text-input detection

    /// True when the key window's first responder is an editable text view/field, so
    /// the field — not the router — should receive the key.
    private static func defaultTextInputCheck() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }
}
