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
        // A solid translucent fill (no live blur) reads over any frame yet stays cheap to
        // composite, so revealing the bar over video doesn't stall the video's redraw.
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        // Light controls/text over the dark fill.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Transport row

    private var controlRow: some View {
        HStack(spacing: 10) {
            transportButton("backward.fill") { coordinator.previous(playlist) }
            if showsPlayPause {
                transportButton(isPaused ? "play.fill" : "pause.fill") { coordinator.togglePause(playlist) }
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

            Button { overlays.isFilesTagsOpen ? overlays.closeFilesTags() : overlays.openFilesTags() } label: {
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
            Text(format(coordinator.visualCurrentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: scrubBinding, in: 0...max(coordinator.visualDuration, 0.1))
                .disabled(coordinator.visualDuration <= 0)

            Text(format(coordinator.visualDuration))
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
            ForEach([3.0, 5.0, 10.0, 15.0, 30.0], id: \.self) { seconds in
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
        playlist.preferences.slideshowInterval ?? appState.globalSettings.defaultSlideshowInterval
    }

    // MARK: - Helpers

    private var isPaused: Bool { playlist.playbackState == .paused }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A control-bar button style that reads as a button: padding gives it a real hit
/// target, and a rounded fill appears on hover and deepens on press, so the controls
/// are visibly interactive rather than bare glyphs.
private struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.22 : (hovering ? 0.13 : 0)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
