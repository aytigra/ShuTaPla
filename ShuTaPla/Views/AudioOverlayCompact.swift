//
//  AudioOverlayCompact.swift
//  ShuTaPla
//
//  The compact audio overlay: a slim bar that slides down from the top edge with the
//  current track and its transport — play/pause (the audio playlist's own Paused
//  state, separate from `[p]` suppression), previous/next, stop, scrubber, volume, and
//  loop. A chevron expands it into the extended overlay. It controls the coordinator's
//  independent audio channel, so it coexists with video/image playback or Manager mode.
//

import SwiftUI

struct AudioOverlayCompact: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    var body: some View {
        HStack(spacing: 12) {
            trackInfo
            // Anchored on the *active* audio playlist, not the loaded channel: Stop removes the
            // playlist from the channel but leaves it active, so the transport stays on screen to
            // restart it. Controls that act on a running channel are disabled until it's live.
            if let audio = appState.activeAudioPlaylist {
                Divider().frame(height: 22)
                transport(audio)
                scrubber(audio)
                Divider().frame(height: 22)
                AudioVolumeControl(playlist: audio)
                loopButton(audio)
            }
            Spacer(minLength: 8)
            expandButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .playerOverlayPanel(opacity: 0.9)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.currentAudioFile?.fileName ?? "No track playing")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let name = appState.activeAudioPlaylist?.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 160, alignment: .leading)
    }

    // MARK: - Transport

    private func transport(_ audio: Playlist) -> some View {
        let isLive = coordinator.audioPlaylist === audio
        return HStack(spacing: 8) {
            controlButton("backward.fill") { coordinator.previous(audio) }
                .disabled(!isLive)
            controlButton(audio.playbackState == .playing ? "pause.fill" : "play.fill") {
                coordinator.togglePlayback(audio)
            }
            controlButton("stop.fill") { coordinator.stop(audio) }
                .disabled(!isLive)
            controlButton("forward.fill") { coordinator.next(audio) }
                .disabled(!isLive)
        }
    }

    private func scrubber(_ audio: Playlist) -> some View {
        HStack(spacing: 8) {
            Text(coordinator.audioCurrentTime.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { min(coordinator.audioCurrentTime, max(coordinator.audioDuration, 0.1)) },
                set: { coordinator.seek(audio, to: $0) }
            ), in: 0...max(coordinator.audioDuration, 0.1))
            .frame(width: 160)
            .disabled(coordinator.audioDuration <= 0)
            Text(coordinator.audioDuration.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func loopButton(_ audio: Playlist) -> some View {
        Button { coordinator.toggleLoop(audio) } label: {
            Image(systemName: "repeat")
                .font(.title3)
                .foregroundStyle(coordinator.isAudioLooping ? Color.accentColor : .primary)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(ControlButtonStyle())
        .disabled(coordinator.audioPlaylist !== audio)
        .help("Loop current track")
    }

    private var expandButton: some View {
        Button { overlays.expandAudioToExtended() } label: {
            Image(systemName: "chevron.down")
                .font(.callout.weight(.semibold))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(ControlButtonStyle())
        .help("Expand audio")
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(ControlButtonStyle())
    }
}

/// The per-playlist volume slider, shared by the compact and extended audio overlays.
struct AudioVolumeControl: View {
    let playlist: Playlist
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { coordinator.playbackVolume(for: playlist) },
                set: { coordinator.setVolume(playlist, to: $0) }
            ), in: 0...1)
            .frame(width: 90)
        }
    }
}
