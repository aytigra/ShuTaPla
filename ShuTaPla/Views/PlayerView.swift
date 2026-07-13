//
//  PlayerView.swift
//  ShuTaPla
//
//  The fullscreen playback container. It shows the active visual channel (video or
//  image), drives the window into fullscreen while it is on screen, and hosts the
//  pause overlay. Keyboard input is owned app-wide by `HotkeyRouter`. The edge hover
//  zones drive the `OverlayManager`; this view composes its overlay content: the bottom
//  controls bar, the left playlists selector, and the Visual Overlay. The independent
//  audio overlay is layered above by `RootView`.
//

import SwiftUI
import SwiftData

struct PlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    /// Width of the bottom controls and their matching hover trigger, so revealing
    /// the bar never pulls the cursor off the strip that triggered it.
    private let bottomControlsWidth: CGFloat = 640

    /// Holds the display-sleep assertion alive across body re-evaluations.
    @State private var sleepBlocker = DisplaySleepBlocker()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.visualKind {
            case .video: VideoPlayerView()
            case .image: ImagePlayerView()
            default: EmptyView()
            }

            // The video render surface is an AppKit view that doesn't see SwiftUI taps, so a
            // transparent layer over it carries the content click. The image player attaches the
            // same behavior to its own gesture stack, where pan/zoom must keep working.
            if coordinator.visualKind == .video {
                Color.clear
                    .contentShape(Rectangle())
                    .playerContentClick()
            }

            if visualHasNoFiles {
                noFilesPlaceholder
            }

            if let pending = coordinator.visualCloudPendingFile {
                CloudDownloadingPlaceholder(file: pending)
                    .ignoresSafeArea()
                    .transition(.opacity)
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
        .background(CursorAutoHider(isActive: cursorShouldAutoHide))
        .overlay(alignment: .bottom) { bottomControlsContainer }
        .overlay { visualOverlayContainer }
        .animation(.easeInOut(duration: 0.15), value: coordinator.isSuppressed)
        .animation(.easeInOut(duration: 0.2), value: visualHasNoFiles)
        .animation(.easeInOut(duration: 0.2), value: coordinator.visualCloudPendingFile != nil)
        // Keep the display awake while the picture is moving; release it on pause and on exit
        // so a paused or torn-down player lets the screen sleep normally again.
        .onChange(of: coordinator.isVisuallyPlaying, initial: true) { _, playing in
            sleepBlocker.isActive = playing
        }
        // Drop every overlay when the player exits, so re-entering starts clean instead
        // of flashing the overlay that was open at stop and then dismissing it.
        .onDisappear {
            overlays.hideAll()
            sleepBlocker.isActive = false
        }
        // Pause advancement while the Visual Overlay is open so it can't jump to the next
        // file mid-edit; resume when it closes.
        .onChange(of: overlays.isVisualOverlayOpen) { _, open in
            open ? coordinator.haltVisualForOverlay() : coordinator.resumeVisualForOverlay()
        }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { appState.pendingConfirmation?.playerDeleteFile != nil },
                set: { if !$0 { appState.cancelConfirmation() } }
            ),
            presenting: appState.pendingConfirmation?.playerDeleteFile
        ) { file in
            Button("Move to Trash", role: .destructive) { appState.confirmConfirmation() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelConfirmation() }
                .keyboardShortcut(.cancelAction)
        } message: { file in
            Text("“\(file.fileName)” is moved to the Trash and removed from this playlist.")
        }
        .alert(
            "Remove Audio?",
            isPresented: Binding(
                get: { appState.pendingConfirmation?.audioStripFiles != nil },
                set: { if !$0 { appState.cancelConfirmation() } }
            )
        ) {
            Button("Remove Audio", role: .destructive) { appState.confirmConfirmation() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelConfirmation() }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("The original is moved to the Trash; playback resumes where it left off.")
        }
    }

    /// Shown when the active filter excludes every file: the player stays in Player
    /// mode on a placeholder rather than dropping back to Manager.
    private var noFilesPlaceholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 48))
                Text("No files match the filter")
                    .font(.headline)
            }
            .foregroundStyle(.white.opacity(0.75))
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    /// Whether the visual playlist's filtered playback sequence is empty.
    private var visualHasNoFiles: Bool {
        _ = appState.sequenceVersion   // re-derive when the playlist's membership changes
        guard let visual = coordinator.liveVisualPlaylist else { return false }
        return !visual.hasPlaybackFiles
    }

    /// Auto-hide the cursor only during uninterrupted playback with no overlay on screen
    /// to interact with.
    private var cursorShouldAutoHide: Bool {
        coordinator.isVisuallyPlaying && overlays.active.isEmpty
    }

    // MARK: - Hover containers
    //
    // The bottom controls occupy a fixed bottom-center spot and stay transparent until the
    // cursor hovers their footprint, then fade in (an opacity-0 view keeps receiving hover).

    @ViewBuilder
    private var bottomControlsContainer: some View {
        if let visual = coordinator.liveVisualPlaylist, !coordinator.isSuppressed {
            let revealed = overlays.active.contains(.bottomControls)
            PlaybackControlsBar(playlist: visual)
                .frame(width: bottomControlsWidth)
                .padding(.bottom, 28)
                .opacity(revealed ? 1 : 0)
                .onHover { hovering in
                    hovering ? overlays.show(.bottomControls) : overlays.hide(.bottomControls)
                }
                .animation(.easeInOut(duration: 0.2), value: revealed)
        }
    }

    /// Opened by `[tab]`/`[arrow up]` or the bottom bar's button — not by hover — and
    /// slides up from the bottom over the player.
    @ViewBuilder
    private var visualOverlayContainer: some View {
        if overlays.active.contains(.visualOverlay), !coordinator.isSuppressed,
           let visual = coordinator.liveVisualPlaylist {
            VisualOverlay(playlist: visual)
                // Leave the top-edge audio hover zone uncovered so the overlay's close button
                // clears it instead of fighting it for the cursor.
                .padding(.top, AppConstants.audioHoverZoneHeight)
                .transition(.move(edge: .bottom))
        }
    }
}
