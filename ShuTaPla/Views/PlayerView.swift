//
//  PlayerView.swift
//  ShuTaPla
//
//  The fullscreen playback container. It shows the active visual channel (video or
//  image), drives the window into fullscreen while it is on screen, and hosts the
//  pause overlay. Only the basic `[p]`/`[esc]`/`[space]` keys are handled here; the
//  full hotkey routing and the hover overlays arrive in Tasks 12–14.
//

import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.visualKind {
            case .video: VideoPlayerView()
            case .image: ImagePlayerView()
            default: EmptyView()
            }

            if coordinator.isSuppressed {
                PauseOverlay(
                    onUnpause: { coordinator.unsuppress() },
                    onStop: { appState.stopAndExitPlayer() }
                )
                .transition(.opacity)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(action: handleKey)
        .background(FullscreenView())
        .overlay(alignment: .topLeading) { backButton }
        .animation(.easeInOut(duration: 0.15), value: coordinator.isSuppressed)
    }

    /// Temporary exit control until the player overlays land (Task 14). Stops the
    /// visual playlist and returns to Manager.
    private var backButton: some View {
        Button {
            appState.stopAndExitPlayer()
        } label: {
            Label("Back to Manager", systemImage: "chevron.left")
        }
        .padding()
        .opacity(coordinator.isSuppressed ? 0 : 1)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case "p":
            coordinator.suppress()
            return .handled
        case .escape:
            if !coordinator.isSuppressed { coordinator.suppress() }
            return .handled
        case .space:
            if coordinator.isSuppressed {
                coordinator.unsuppress()
            } else if let visual = coordinator.visualPlaylist {
                coordinator.next(visual)
            }
            return .handled
        default:
            return .ignored
        }
    }
}
