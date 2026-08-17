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
        // The Manager "peek" card, above every mode and overlay but inside the safe area, so its
        // dimmed backdrop stops at the toolbar rather than under the window chrome. It lives in its
        // own overlay with a self-contained animation: were the fade on the outer ZStack, closing
        // the preview would pull the AppKit-hosted Manager split view into the same transaction and
        // its panes would fade unevenly. Scoped here, only the backdrop and card animate.
        .overlay {
            ZStack {
                if appState.preview.isOpen {
                    MediaPreviewView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.preview.isOpen)
            .environment(appState.preview)
        }
        .environment(overlayManager)
        // Every destructive confirmation, from one host: the enum allows only one pending at a
        // time, so one alert presents them all, worded by the enum itself. Hosting them here rather
        // than at each raising surface is what lets `HotkeyRouter` hold the keyboard for them — and
        // keeps a confirmation on screen when the panel that raised it goes away under it.
        .alert(
            appState.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { appState.pendingConfirmation != nil },
                set: { if !$0 { appState.cancelConfirmation() } }
            ),
            presenting: appState.pendingConfirmation
        ) { pending in
            Button(pending.confirmLabel, role: .destructive) { appState.confirmConfirmation() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelConfirmation() }
                .keyboardShortcut(.cancelAction)
        } message: { pending in
            Text(pending.message)
        }
        // A persist failure is surfaced app-wide: any mutation surface could have raised it, and
        // `persistAndRefresh` has already rolled the context back to keep the model consistent.
        .alert(
            "Couldn’t save your changes",
            isPresented: Binding(
                get: { appState.saveError != nil },
                set: { if !$0 { appState.saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.saveError = nil }
        } message: {
            Text(appState.saveError ?? "")
        }
        // An operation failed or was refused, wherever it was raised from. Presented app-wide from
        // one host so the audio overlay (which co-mounts over the Manager panel) can't double-present
        // it, and so a surface that goes away mid-operation still gets its report shown; the carried
        // title names the site.
        .alert(
            appState.errorNotice?.title ?? "",
            isPresented: Binding(
                get: { appState.errorNotice != nil },
                set: { if !$0 { appState.errorNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.errorNotice = nil }
        } message: {
            Text(appState.errorNotice?.message ?? "")
        }
        .addPlaylistFlow()
        .background(WindowCloseBridge { appState.windowWasClosed() })
        .background(WindowFrameBridge(
            restoredFrame: { appState.restoredWindowFrame },
            onFrameChange: { appState.persistWindowFrame($0) }
        ))
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

    /// The top-anchored audio overlay: a thin top-edge hover trigger plus the unified compact /
    /// expanded overlay. Empty areas don't intercept hits, so the mode content underneath stays
    /// interactive; the expanded overlay's own opaque panel captures input while open.
    @ViewBuilder
    private var audioOverlayLayer: some View {
        let suppressed = coordinator.isSuppressed
        let audioActive = !overlayManager.active.isDisjoint(with: [.audioCompact, .audioExtended])

        ZStack(alignment: .top) {
            // The hover trigger is as tall as the compact bar, so it's an easy target along the
            // top edge rather than a sliver fighting the system's menu-bar / traffic-light reveal,
            // and moving the cursor onto the revealed bar never leaves the tracking region (the
            // bar draws on top and still receives clicks). Behind the full-screen expanded overlay
            // it is harmless — `hideCompactAudioOnHoverExit` only touches compact audio.
            if !suppressed {
                HoverZone(
                    onEnter: { overlayManager.revealCompactAudioOnHover() },
                    onExit: { overlayManager.hideCompactAudioOnHoverExit() }
                )
                .frame(height: AppConstants.audioHoverZoneHeight)
                .frame(maxWidth: .infinity)
            }

            if audioActive {
                AudioOverlay()
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
