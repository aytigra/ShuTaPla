//
//  PlayerContentClick.swift
//  ShuTaPla
//
//  The click behavior of the Player-mode content area: a single click toggles the visual
//  channel's play/pause, a double click stops and returns to Manager. Both verbs route to
//  the same APIs the bottom controls and hotkeys use, so the content is just another way to
//  reach them.
//

import SwiftUI
import AppKit

private struct PlayerContentClickModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator

    func body(content: Content) -> some View {
        // One tap gesture branched on the event's click count: a lone single click fires
        // immediately (no waiting out the double-click interval), and a double click fires it
        // again with `clickCount == 2`. Stacking separate `count: 1` / `count: 2` gestures would
        // delay the single-click pause by the system double-click interval.
        content.onTapGesture {
            guard let visual = coordinator.liveVisualPlaylist, !coordinator.isSuppressed else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                appState.stopAndExitPlayer()
            } else {
                coordinator.togglePauseIfActive(visual)
            }
        }
    }
}

extension View {
    /// Single click toggles play/pause; double click stops and exits Player mode.
    func playerContentClick() -> some View {
        modifier(PlayerContentClickModifier())
    }
}
