//
//  PlayerView.swift
//  ShuTaPla
//
//  The fullscreen playback container. It shows the active visual channel (video or
//  image), drives the window into fullscreen while it is on screen, and hosts the
//  pause overlay. Keyboard input is owned app-wide by `HotkeyRouter` (Task 12). The
//  edge hover zones (Task 13) drive the `OverlayManager`; this view composes its
//  overlay content (Task 14): the bottom controls bar, the left playlists selector,
//  and the Files & Tags overlay. (Compact/extended audio content arrives in Task 15.)
//

import SwiftUI

struct PlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    /// Thickness of the invisible edge strips that trigger the hover overlays.
    private let hoverThickness: CGFloat = 4

    /// Width of the bottom controls and their matching hover trigger, so revealing
    /// the bar never pulls the cursor off the strip that triggered it.
    private let bottomControlsWidth: CGFloat = 640

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.visualKind {
            case .video: VideoPlayerView()
            case .image: ImagePlayerView()
            default: EmptyView()
            }

            if visualHasNoFiles {
                noFilesPlaceholder
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
        .overlay(alignment: .leading) { playlistsContainer }
        .overlay(alignment: .bottom) { bottomControlsContainer }
        .overlay(alignment: .top) { topAudioHoverStrip }
        .overlay { filesTagsContainer }
        .animation(.easeInOut(duration: 0.15), value: coordinator.isSuppressed)
        .animation(.easeInOut(duration: 0.2), value: visualHasNoFiles)
        // Drop every overlay when the player exits, so re-entering starts clean instead
        // of flashing the overlay that was open at stop and then dismissing it.
        .onDisappear { overlays.hideAll() }
        // Pause advancement while Files & Tags is open so it can't jump to the next
        // file mid-edit; resume when it closes.
        .onChange(of: overlays.isFilesTagsOpen) { _, open in
            open ? coordinator.haltVisualForOverlay() : coordinator.resumeVisualForOverlay()
        }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { appState.playerDeleteCandidate != nil },
                set: { if !$0 { appState.cancelPlayerDelete() } }
            ),
            presenting: appState.playerDeleteCandidate
        ) { file in
            Button("Move to Trash", role: .destructive) { appState.confirmPlayerDelete() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelPlayerDelete() }
                .keyboardShortcut(.cancelAction)
        } message: { file in
            Text("“\(file.fileName)” is moved to the Trash and removed from this playlist.")
        }
        .alert(
            "Remove Audio?",
            isPresented: Binding(
                get: { !appState.pendingAudioStrip.isEmpty },
                set: { if !$0 { appState.cancelAudioStrip() } }
            )
        ) {
            Button("Remove Audio", role: .destructive) { appState.confirmAudioStrip() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelAudioStrip() }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("The original is moved to the Trash; playback resumes where it left off.")
        }
        .alert(
            "Couldn't remove audio",
            isPresented: Binding(get: { appState.audioStripError != nil }, set: { if !$0 { appState.audioStripError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.audioStripError = nil }
        } message: {
            Text(appState.audioStripError ?? "")
        }
        .alert(
            "Couldn't move to Trash",
            isPresented: Binding(get: { appState.playerDeleteError != nil }, set: { if !$0 { appState.playerDeleteError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.playerDeleteError = nil }
        } message: {
            Text(appState.playerDeleteError ?? "")
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
        guard let visual = coordinator.visualPlaylist else { return false }
        return !visual.hasPlaybackFiles
    }

    /// Auto-hide the cursor only during uninterrupted playback: a visual playlist is
    /// playing, nothing is suppressing it, and no overlay is on screen to interact with.
    private var cursorShouldAutoHide: Bool {
        guard let visual = coordinator.visualPlaylist else { return false }
        return visual.playbackState == .playing && !coordinator.isSuppressed && overlays.active.isEmpty
    }

    // MARK: - Hover containers
    //
    // The bottom controls occupy a fixed bottom-center spot and stay transparent until the
    // cursor hovers their footprint, then fade in (an opacity-0 view keeps receiving hover).
    // The left Playlists overlay is triggered by a thin edge `HoverZone`, and the revealed
    // panel carries `.onHover` to dismiss itself when the cursor leaves.

    @ViewBuilder
    private var bottomControlsContainer: some View {
        if let visual = coordinator.visualPlaylist, !coordinator.isSuppressed {
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

    @ViewBuilder
    private var playlistsContainer: some View {
        let open = overlays.active.contains(.playlistsSidebar) && !coordinator.isSuppressed
        ZStack(alignment: .leading) {
            HoverZone(
                onEnter: { if !coordinator.isSuppressed { overlays.show(.playlistsSidebar) } },
                onExit: {}
            )
            .frame(width: hoverThickness)
            .frame(maxHeight: .infinity)

            if open {
                PlaylistsOverlay()
                    .contentShape(Rectangle())
                    .onHover { if !$0 { overlays.hide(.playlistsSidebar) } }
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(!coordinator.isSuppressed)
    }

    /// Top-edge trigger for the compact audio overlay. Its content lands in Task 15; the
    /// strip already drives the `OverlayManager` so the wiring is in place.
    private var topAudioHoverStrip: some View {
        HoverZone(
            onEnter: { if !coordinator.isSuppressed { overlays.revealCompactAudio() } },
            onExit: { overlays.hide(.audioCompact) }
        )
        .frame(maxWidth: .infinity)
        .frame(height: hoverThickness)
        .allowsHitTesting(!coordinator.isSuppressed)
    }

    /// Opened by `[tab]`/`[arrow up]` or the bottom bar's button — not by hover — and
    /// slides up from the bottom over the player.
    @ViewBuilder
    private var filesTagsContainer: some View {
        if overlays.active.contains(.filesTags), !coordinator.isSuppressed,
           let visual = coordinator.visualPlaylist {
            FilesTagsOverlayView(playlist: visual)
                .transition(.move(edge: .bottom))
        }
    }
}
