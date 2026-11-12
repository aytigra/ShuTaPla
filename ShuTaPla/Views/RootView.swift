//
//  RootView.swift
//  ShuTaPla
//
//  Top-level view that switches the window between Welcome, Manager, and Player
//  based on `AppState.mode`. In Player mode it also mounts the audio overlay layer
//  (compact and extended) above the player. It owns the single shared folder chooser
//  and add-playlist flow that every entry point triggers.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @State private var hotkeyRouter = HotkeyRouter()

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
        .environment(appState.overlays)
        // Every destructive confirmation, from one host: one is pending at a time, so one alert
        // presents them all, worded by the enum itself. Each app-root modal shows when it is the
        // head of `AppState.windowModals`.
        .alert(
            appState.pendingConfirmation?.title ?? "",
            isPresented: appState.isPresented(.confirmation) { appState.cancelConfirmation() },
            presenting: appState.pendingConfirmation
        ) { pending in
            Button(pending.confirmLabel, role: .destructive) { appState.confirmConfirmation() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelConfirmation() }
                .keyboardShortcut(.cancelAction)
        } message: { pending in
            Text(pending.message)
        }
        // An operation failed or was refused, wherever it was raised from. Presented from one host
        // so the audio overlay (which co-mounts over the player) can't double-present it; the
        // carried title names the site.
        .alert(
            appState.errorNotice?.title ?? "",
            isPresented: appState.isPresented(.report) { appState.dismissErrorNotice() }
        ) {
            // The binding is the one dismiss path: an action here would remove two reports.
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorNotice?.message ?? "")
        }
        // A quit during disk work: the list shrinks as each file is done, and the app quits by
        // itself when it is empty (`AppState.shouldTerminate`).
        .alert(
            "Waiting to Quit",
            isPresented: appState.isPresented(.quitWait) { appState.cancelQuit() }
        ) {
            Button("Cancel Quitting", role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            // The message runs in this body: the list (a store fetch) is read only while a quit waits.
            Text(appState.isWaitingToQuit
                 ? "\(AppConstants.appName) quits when this work ends:\n\(appState.quitWaitItems.joined(separator: "\n"))"
                 : "")
        }
        .folderPickFlow()
        .addPlaylistFlow()
        .background(WindowNotificationBridge([NSWindow.willCloseNotification]) { _, _ in
            appState.windowWasClosed()
        })
        .background(WindowNotificationBridge(
            [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification]
        ) { name, window in
            // A sheet queued behind the one that ended is still attached.
            appState.windowHasSheet = name == NSWindow.willBeginSheetNotification || window.attachedSheet != nil
        })
        // Player mode claims the window's fullscreen state for as long as it runs, and the mode
        // drives that directly: the window is permanent, so nothing about it can be tied to how long
        // a particular view is on screen. Outside the claim the window is the user's.
        .background(WindowFullscreenBridge(isFullscreen: appState.mode == .player))
        .background(WindowFrameBridge(
            restoredFrame: { appState.restoredWindowFrame },
            onFrameChange: { appState.persistWindowFrame($0) }
        ))
        // The pause overlay covers the whole screen, so suppression clears every overlay
        // (including audio) — matching the feature spec's "pause overlay clears everything".
        .onChange(of: coordinator.isSuppressed) { _, suppressed in
            if suppressed { appState.overlays.hideAll() }
        }
        .onAppear {
            hotkeyRouter.appState = appState
            hotkeyRouter.overlayContext = appState.overlays
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
        let audioActive = !appState.overlays.active.isDisjoint(with: [.audioCompact, .audioExtended])

        ZStack(alignment: .top) {
            // The hover trigger is as tall as the compact bar, so it's an easy target along the
            // top edge rather than a sliver fighting the system's menu-bar / traffic-light reveal,
            // and moving the cursor onto the revealed bar never leaves the tracking region (the
            // bar draws on top and still receives clicks). Behind the full-screen expanded overlay
            // it is harmless — `hideCompactAudioOnHoverExit` only touches compact audio.
            if !suppressed {
                HoverZone(
                    onEnter: { appState.overlays.revealCompactAudioOnHover() },
                    onExit: { appState.overlays.hideCompactAudioOnHoverExit() }
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
            appState.overlays.audioDidFullyReveal()
        }
    }
}
