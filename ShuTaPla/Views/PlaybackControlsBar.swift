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
            if playlist.mediaType == .video { timeline }
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
            transportButton("backward.fill") { coordinator.previous(playlist) }
            if showsPlayPause {
                transportButton(isPaused ? "play.fill" : "pause.fill") { coordinator.togglePauseIfActive(playlist) }
            }
            transportButton("stop.fill") { appState.stopAndExitPlayer() }
            transportButton("forward.fill") { coordinator.next(playlist) }

            Divider().frame(height: 22)

            if playlist.mediaType == .video {
                loopButton
                volumeControl
            } else {
                slideshowToggle
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
        playlist.mediaType != .image || playlist.preferences.slideshowEnabled
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(ControlButtonStyle())
    }

    // MARK: - Video controls

    private var timeline: some View {
        HStack(spacing: 10) {
            Text(coordinator.visualCurrentTime.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: scrubBinding, in: 0...max(coordinator.visualDuration, 0.1))
                .disabled(coordinator.visualDuration <= 0)

            Text(coordinator.visualDuration.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { min(coordinator.visualCurrentTime, max(coordinator.visualDuration, 0.1)) },
            set: { coordinator.seek(playlist, to: $0) }
        )
    }

    private var loopButton: some View {
        Button { coordinator.toggleLoop(playlist) } label: {
            Image(systemName: "repeat")
                .font(.title3)
                .foregroundStyle(coordinator.isVisualLooping ? Color.accentColor : .primary)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(ControlButtonStyle())
        .help("Loop current file")
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { coordinator.playbackVolume(for: playlist) },
                set: { coordinator.setVolume(playlist, to: $0) }
            ), in: 0...1)
            .frame(width: 110)
        }
    }

    // MARK: - Image controls

    private var slideshowToggle: some View {
        Button { coordinator.setSlideshowEnabled(playlist, !playlist.preferences.slideshowEnabled) } label: {
            Image(systemName: playlist.preferences.slideshowEnabled ? "pause.rectangle" : "play.rectangle")
                .font(.title3)
                .foregroundStyle(playlist.preferences.slideshowEnabled ? Color.accentColor : .primary)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(ControlButtonStyle())
        .help("Toggle slideshow")
    }

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

}
