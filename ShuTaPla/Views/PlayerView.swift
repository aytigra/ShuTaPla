//
//  PlayerView.swift
//  ShuTaPla
//
//  The fullscreen playback container. It shows the active visual channel (video or
//  image), drives the window into fullscreen while it is on screen, and hosts the
//  pause overlay. Keyboard input is owned app-wide by `HotkeyRouter` (Task 12); the
//  edge hover zones (Task 13) drive the `OverlayManager`, whose overlay content the
//  player composes in Task 14.
//

import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    /// Thickness of the invisible edge strips that trigger the hover overlays.
    private let hoverThickness: CGFloat = 4

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
        .overlay { hoverZones }
        .overlay(alignment: .topLeading) { backButton }
        .animation(.easeInOut(duration: 0.15), value: coordinator.isSuppressed)
    }

    /// Invisible edge strips that summon the hover overlays: top → compact audio,
    /// left → playlists, bottom → playback controls. The `OverlayManager` enforces
    /// which can actually appear; the overlay content itself is composed in Task 14.
    private var hoverZones: some View {
        ZStack {
            VStack(spacing: 0) {
                HoverZone(
                    onEnter: { overlays.revealCompactAudio() },
                    onExit: { overlays.hide(.audioCompact) }
                )
                .frame(height: hoverThickness)
                Spacer(minLength: 0)
                HoverZone(
                    onEnter: { overlays.show(.bottomControls) },
                    onExit: { overlays.hide(.bottomControls) }
                )
                .frame(height: hoverThickness)
            }
            HStack(spacing: 0) {
                HoverZone(
                    onEnter: { overlays.show(.playlistsSidebar) },
                    onExit: { overlays.hide(.playlistsSidebar) }
                )
                .frame(width: hoverThickness)
                Spacer(minLength: 0)
            }
        }
        .allowsHitTesting(!coordinator.isSuppressed)
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
