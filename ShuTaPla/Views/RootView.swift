//
//  RootView.swift
//  ShuTaPla
//
//  Top-level view that switches the window between Welcome, Manager, and Player
//  based on `AppState.mode`. It also mounts the audio overlay layer (compact and
//  extended) above whichever mode is showing, since the audio channel is independent
//  and coexists with Manager and Player alike, and owns the single shared
//  add-playlist flow that every entry point triggers.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @State private var hotkeyRouter = HotkeyRouter()
    @State private var overlayManager = OverlayManager()

    var body: some View {
        ZStack(alignment: .top) {
            switch appState.mode {
            case .welcome:
                WelcomeView()
            case .manager:
                ManagerView()
            case .player:
                PlayerView()
            }

            if appState.mode == .player {
                audioOverlayLayer
            }
        }
        .environment(overlayManager)
        .addPlaylistFlow()
        // The pause overlay covers the whole screen, so suppression clears every overlay
        // (including audio) — matching the feature spec's "pause overlay clears everything".
        .onChange(of: coordinator.isSuppressed) { _, suppressed in
            if suppressed { overlayManager.hideAll() }
        }
        .onAppear {
            hotkeyRouter.appState = appState
            hotkeyRouter.overlayContext = overlayManager
            hotkeyRouter.startMonitoring()
        }
        .onDisappear { hotkeyRouter.stopMonitoring() }
    }

    /// The top-anchored audio overlay: a thin top-edge hover trigger plus the compact /
    /// extended content. Empty areas don't intercept hits, so the mode content underneath
    /// stays interactive; the extended overlay's own opaque panel captures input while open.
    @ViewBuilder
    private var audioOverlayLayer: some View {
        let suppressed = coordinator.isSuppressed
        let compactRevealed = overlayManager.active.contains(.audioCompact)
        let audioActive = !overlayManager.active.isDisjoint(with: [.audioCompact, .audioExtended])

        ZStack(alignment: .top) {
            // The hover trigger grows from a thin top strip to cover the revealed bar, so
            // moving the cursor onto the bar never leaves the tracking region and closes it
            // (the bar draws on top and still receives clicks). Behind the full-screen
            // extended overlay it is harmless — `hideCompactAudioOnHoverExit` only touches
            // compact audio.
            if !suppressed {
                HoverZone(
                    onEnter: { overlayManager.revealCompactAudioOnHover() },
                    onExit: { overlayManager.hideCompactAudioOnHoverExit() }
                )
                .frame(height: compactRevealed ? 60 : 4)
                .frame(maxWidth: .infinity)
            }

            if overlayManager.active.contains(.audioExtended) {
                AudioOverlayExtended()
                    .transition(.move(edge: .top))
            } else if compactRevealed, !suppressed {
                AudioOverlayCompact()
                    .transition(.move(edge: .top))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Grant the audio overlay key context once its slide-in completes (and only if it's
        // still on screen) — a top-edge graze that leaves first cancels this task.
        .task(id: audioActive) {
            guard audioActive else { return }
            try? await Task.sleep(for: .seconds(0.2))
            overlayManager.audioDidFullyReveal()
        }
    }
}
