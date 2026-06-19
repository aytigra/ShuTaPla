//
//  OverlayManager.swift
//  ShuTaPla
//
//  The single owner of Player-mode overlay visibility. Overlays are tracked as a
//  `Set<Overlay>` (a flat set, not a stack — overlays don't nest arbitrarily), and
//  every `show(_:)` enforces the exclusivity rules from the feature spec before the
//  overlay is inserted. It also owns **key context** — whether the player or a fully
//  revealed audio overlay receives arrow/space/loop/seek — which the `HotkeyRouter`
//  reads through its `HotkeyOverlayContext` seam (this type is that context).
//
//  Show/hide run inside `withAnimation` so the SwiftUI `.transition(.move(edge:))`
//  overlays slide in and out; the set mutation itself is a pure function so the
//  exclusivity rules are unit-testable without a view.
//

import SwiftUI

@MainActor @Observable
final class OverlayManager: HotkeyOverlayContext {

    enum Overlay: Hashable {
        case filesTags
        case playlistsSidebar
        case audioCompact
        case audioExtended
        case pauseOverlay
        case bottomControls
    }

    /// The overlays currently on screen. Read by the player view layer to compose its
    /// `.overlay()`/`.transition()` modifiers.
    private(set) var active: Set<Overlay> = []

    /// Set by the audio overlay once its slide-in animation completes (Task 15) and
    /// cleared whenever no audio overlay remains active. Gates `audioHoldsKeyContext`:
    /// the audio overlay claims key context only when *fully revealed*, not the moment
    /// it begins to appear.
    private(set) var audioFullyRevealed = false

    /// Closable overlays in topmost-first order — the ones the user explicitly opened;
    /// `[esc]`/`closeTopmostOverlay()` and `isAnyOverlayOpen` consider exactly these.
    /// Bottom controls are passive hover chrome and aren't closed by `[esc]`.
    private static let closablePriority: [Overlay] =
        [.audioExtended, .filesTags, .audioCompact, .playlistsSidebar]

    private static let closableSet = Set(closablePriority)

    private static let audioSet: Set<Overlay> = [.audioCompact, .audioExtended]

    static let transition: Animation = .easeInOut(duration: 0.2)

    // MARK: - Show / hide

    func show(_ overlay: Overlay) {
        withAnimation(Self.transition) { applyShow(overlay) }
    }

    func hide(_ overlay: Overlay) {
        withAnimation(Self.transition) { applyHide(overlay) }
    }

    func hideAll() {
        withAnimation(Self.transition) {
            active.removeAll()
            audioFullyRevealed = false
        }
    }

    /// Mutates `active` per the exclusivity rules. Pure (no animation) so the rules are
    /// unit-testable and so several mutations can share one `withAnimation` transaction.
    private func applyShow(_ overlay: Overlay) {
        switch overlay {
        case .audioExtended:                 // exclusive — closes everything else
            active.remove(.filesTags)
            active.remove(.playlistsSidebar)
            active.remove(.audioCompact)
            active.remove(.bottomControls)
        case .filesTags:                     // hotkey overlay — closes compact audio + hover overlays
            active.remove(.audioCompact)
            active.remove(.playlistsSidebar)
            active.remove(.bottomControls)
        case .audioCompact:
            // Compact audio may sit on top of an open Files & Tags overlay (top-edge hover),
            // so it does NOT close it. It only yields to Extended audio (handled above).
            break
        case .playlistsSidebar, .bottomControls:
            // Hover overlays are suppressed while Files & Tags or Extended audio is open.
            if active.contains(.filesTags) || active.contains(.audioExtended) { return }
        case .pauseOverlay:                  // suppression UI — opaque, covers the whole screen
            active.removeAll()
        }
        active.insert(overlay)
        syncAudioKeyContext()
    }

    private func applyHide(_ overlay: Overlay) {
        active.remove(overlay)
        syncAudioKeyContext()
    }

    /// Key context belongs to audio only while an audio overlay is actually on screen; drop
    /// the reveal flag the moment the last audio overlay leaves so the player reclaims it.
    private func syncAudioKeyContext() {
        if active.isDisjoint(with: Self.audioSet) { audioFullyRevealed = false }
    }

    // MARK: - HotkeyOverlayContext

    var isAnyOverlayOpen: Bool { !active.isDisjoint(with: Self.closableSet) }

    var isFilesTagsOpen: Bool { active.contains(.filesTags) }

    var audioHoldsKeyContext: Bool {
        audioFullyRevealed && !active.isDisjoint(with: Self.audioSet)
    }

    func closeTopmostOverlay() {
        guard let top = Self.closablePriority.first(where: active.contains) else { return }
        hide(top)
    }

    func openFilesTags() { show(.filesTags) }
    func closeFilesTags() { hide(.filesTags) }
    func revealCompactAudio() { show(.audioCompact) }
    func expandAudioToExtended() { show(.audioExtended) }

    func closeAudioOverlay() {
        withAnimation(Self.transition) {
            active.remove(.audioCompact)
            active.remove(.audioExtended)
            audioFullyRevealed = false
        }
    }

    /// Called by the audio overlay once its slide-in animation completes (Task 15), granting
    /// key context to the audio playlist.
    func audioDidFullyReveal() { audioFullyRevealed = true }
}
