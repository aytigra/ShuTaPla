//
//  PlayerView.swift
//  ShuTaPla
//
//  The fullscreen playback container. It shows the active visual channel (video or
//  image), drives the window into fullscreen while it is on screen, and hosts the
//  pause overlay. Keyboard input is owned app-wide by `HotkeyRouter` (Task 12); the
//  hover overlays arrive in Tasks 13–14.
//

import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator

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
}
