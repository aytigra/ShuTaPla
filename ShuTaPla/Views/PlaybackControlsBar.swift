//
//  PlaybackControlsBar.swift
//  ShuTaPla
//
//  The bottom hover control bar. It adapts to the active visual channel: video gets a
//  scrubber, volume slider, and loop toggle; image gets a slideshow toggle and interval
//  selector. The play/pause button flips the playlist's own Playing/Paused state — never
//  suppression — and a Files & Tags button toggles that overlay.
//

import SwiftUI

struct PlaybackControlsBar: View {
    let playlist: Playlist
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    @Environment(OverlayManager.self) private var overlays

    var body: some View {
        VStack(spacing: 10) {
            if playlist.mediaType == .video {
                TimelineScrubber(
                    position: coordinator.visualCurrentTime,
                    duration: coordinator.visualDuration
                ) { coordinator.seek(playlist, to: $0) }
            }
            controlRow
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .playerOverlayPanel(opacity: 0.85, cornerRadius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    // MARK: - Transport row

    private var controlRow: some View {
        HStack(spacing: 10) {
            TransportButton(title: "Previous", systemImage: "backward.fill", size: .bar) {
                coordinator.previous(playlist)
            }
            if showsPlayPause {
                TransportButton(
                    title: isPaused ? "Play" : "Pause",
                    systemImage: isPaused ? "play.fill" : "pause.fill",
                    size: .bar
                ) { coordinator.togglePauseIfActive(playlist) }
            }
            TransportButton(title: "Stop", systemImage: "stop.fill", size: .bar) {
                appState.stopAndExitPlayer()
            }
            TransportButton(title: "Next", systemImage: "forward.fill", size: .bar) {
                coordinator.next(playlist)
            }

            Divider().frame(height: 22)

            if playlist.mediaType == .video {
                TransportButton(
                    title: "Loop current file", systemImage: "repeat",
                    isActive: coordinator.isVisualLooping, size: .bar
                ) { coordinator.toggleLoop(playlist) }
                VolumeControl(playlist: playlist, width: 110)
            } else {
                TransportButton(
                    title: "Toggle slideshow",
                    systemImage: isSlideshowOn ? "pause.rectangle" : "play.rectangle",
                    isActive: isSlideshowOn, size: .bar
                ) { coordinator.setSlideshowEnabled(playlist, !isSlideshowOn) }
                intervalSelector
            }

            Spacer(minLength: 12)

            Button { overlays.isVisualOverlayOpen ? overlays.closeVisualOverlay() : overlays.openVisualOverlay() } label: {
                Label("Files & Tags", systemImage: "list.bullet.rectangle")
                    .font(.callout)
            }
            .buttonStyle(ControlButtonStyle())
        }
        .foregroundStyle(.primary)
    }

    /// Whether the play/pause transport button is shown. A still image has nothing to
    /// pause, so it appears only once a slideshow is running.
    private var showsPlayPause: Bool {
        playlist.mediaType != .image || isSlideshowOn
    }

    // MARK: - Image controls

    private var intervalSelector: some View {
        Menu {
            ForEach(AppConstants.slideshowIntervals, id: \.self) { seconds in
                Button("\(Int(seconds))s") { coordinator.setSlideshowInterval(playlist, seconds) }
            }
        } label: {
            Label("\(Int(currentInterval))s", systemImage: "timer")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentInterval: TimeInterval {
        playlist.effectiveSlideshowInterval(appState.globalSettings)
    }

    // MARK: - Helpers

    private var isPaused: Bool { playlist.playbackState == .paused }

    private var isSlideshowOn: Bool { playlist.preferences.slideshowEnabled }

}
