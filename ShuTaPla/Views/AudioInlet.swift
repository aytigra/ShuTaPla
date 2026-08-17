//
//  AudioInlet.swift
//  ShuTaPla
//
//  The Manager sidebar's pinned audio inlet and the state-dependent transport it shares
//  with the player-mode overlay. The independent audio channel is parallel to whatever
//  Manager scope is being browsed, so the inlet stays at the top of the left panel in both
//  scopes, keeping the active audio playlist controllable while browsing video, images, or
//  audio itself.
//

import SwiftUI
import SwiftData

/// The audio transport, rendering only the controls actionable in the active audio
/// playlist's current state — no dead buttons:
///
/// | State   | Controls                                       |
/// |---------|------------------------------------------------|
/// | Stopped | Play · Volume                                  |
/// | Playing | Previous · Pause · Stop · Next · Loop · Volume  |
/// | Paused  | Previous · Play · Stop · Next · Loop · Volume   |
///
/// Stopped means the playlist is active but off the channel (Stop removed it from it);
/// Previous / Next / Loop / Stop appear only once the channel is live. Shared by the sidebar
/// inlet and the player-mode overlay so the two surfaces drive one set of controls.
struct AudioTransport: View {
    let playlist: Playlist
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState

    @State private var showingVolume = false

    /// Whether the playlist currently occupies the audio channel. Stop removes it from the
    /// channel but leaves it active, collapsing the transport to Play · Volume.
    private var isLive: Bool { coordinator.liveAudioPlaylist === playlist }

    var body: some View {
        let _ = appState.sequences.version   // re-derive the Play affordance when membership changes
        HStack(spacing: 4) {
            CloudStatusBadge(status: appState.currentAudioFile?.cloudStatus ?? .local)
                .foregroundStyle(.secondary)
            if isLive {
                TransportButton(title: "Previous track", systemImage: "backward.fill") {
                    coordinator.previous(playlist)
                }
            }
            TransportButton(
                title: isPlaying ? "Pause" : "Play",
                systemImage: isPlaying ? "pause.fill" : "play.fill"
            ) { coordinator.playOrTogglePause(playlist) }
            // A filter that matches nothing leaves no track to start on, so Play would be a no-op —
            // whereas Pause always applies, since a playing channel has a current file by definition.
            .disabled(!isPlaying && playlist.sequenceEmpty)
            if isLive {
                TransportButton(title: "Stop", systemImage: "stop.fill") { coordinator.stop(playlist) }
                TransportButton(title: "Next track", systemImage: "forward.fill") { coordinator.next(playlist) }
                TransportButton(
                    title: "Loop current track", systemImage: "repeat",
                    isActive: coordinator.isAudioLooping
                ) { coordinator.toggleLoop(playlist) }
            }
            volumeButton
        }
    }

    private var isPlaying: Bool { playlist.playbackState == .playing }

    private var volumeButton: some View {
        TransportButton(title: "Volume", systemImage: "speaker.wave.2.fill") { showingVolume.toggle() }
            .popover(isPresented: $showingVolume, arrowEdge: .bottom) {
                VolumeControl(playlist: playlist, width: 90)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
    }
}

/// The pinned inlet at the top of the Manager sidebar.
///
/// - **No active audio playlist:** a music glyph and a Play that starts the first audio
///   playlist, or raises the add-folder flow when none exist.
/// - **An active audio playlist:** the state-dependent `AudioTransport`. The track name and a
///   thin progress bar appear only once a current track is available (`currentAudioFile`);
///   an active playlist with no current file yet shows just the transport.
struct AudioInlet: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let audio = appState.audioChannelPlaylist {
                active(audio)
            } else {
                idle
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var idle: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Button {
                appState.startFirstAudioPlaylistOrAdd()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(appState.isAddingPlaylist)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func active(_ audio: Playlist) -> some View {
        AudioTransport(playlist: audio)
        if let file = appState.currentAudioFile {
            Text(file.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            seekBar(audio)
        }
    }

    /// The thin progress bar, click- and drag-to-seek: a tap or drag maps the cursor's x to a
    /// fraction of the track and seeks the audio channel there. Disabled until a duration is known.
    private func seekBar(_ audio: Playlist) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.secondary)
                    .frame(width: geo.size.width * coordinator.audioProgressFraction)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        coordinator.seekAudio(toFraction: value.location.x / geo.size.width)
                    }
            )
        }
        .frame(height: 4)
        .disabled(!coordinator.audioIsSeekable)
    }
}
