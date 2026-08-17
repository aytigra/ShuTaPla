//
//  AudioOverlay.swift
//  ShuTaPla
//
//  The player-mode audio overlay: a single layout with a compact and an expanded state. The
//  compact transport bar slides down from the top edge with the current track and its
//  controls; a chevron expands the shared `LibrarySurface` below it — the audio playlists
//  selector, the active playlist's filtered file list, and a tag editor for the current
//  track. It drives the coordinator's independent audio channel, so it coexists with the
//  visual player.
//
//  The lower body comes from `LibrarySurface`, wired through `audioContext`. Playlist
//  creation lives behind the `+`; rename / delete / reorder live in Manager's audio scope,
//  so the playlists panel here is a pure selector — choosing one plays it immediately.
//

import SwiftUI
import AppKit

struct AudioOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    private var isExpanded: Bool { overlays.active.contains(.audioExtended) }
    private var activePlaylist: Playlist? { appState.audioChannelPlaylist }

    /// The audio channel's wiring for the shared library surface: lists audio playlists,
    /// plays on select, and routes a row's delete to the audio-delete confirmation.
    private var audioContext: LibraryContext {
        LibraryContext(
            mediaType: .audio,
            activePlaylist: activePlaylist,
            fileIDs: appState.audioChannelFileIDs,
            currentFile: appState.currentAudioFile,
            scrollTrigger: appState.audioScrollToken,
            tagAutoFocus: false,
            onSelectPlaylist: { appState.playOnAudioChannel($0) },
            onAddPlaylist: { appState.isImportingPlaylist = true },
            onPlayFile: { coordinator.playNow($0, startingAt: $1) },
            onDeleteFile: { appState.requestAudioDelete($0) },
            onRemoveAudio: { _ in }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            compactBar
            if isExpanded {
                Divider()
                LibrarySurface(context: audioContext)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .playerOverlayPanel(opacity: isExpanded ? 1 : 0.9)
        // A click on the expanded panel's empty chrome resigns the tag field so it can be
        // unfocused anywhere, not just by tabbing away.
        .contentShape(Rectangle())
        .onTapGesture { if isExpanded { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    // MARK: - Compact bar

    private var compactBar: some View {
        // Equal flexible side columns pin the transport to the true center, so it holds its
        // place as the left filename changes width; the filename truncates within its column.
        HStack(spacing: 12) {
            trackInfo
                .frame(maxWidth: .infinity, alignment: .leading)
            // Anchored on the *active* audio playlist, not the loaded channel: Stop removes the
            // playlist from the channel but leaves it active, so the transport stays on screen to
            // restart it.
            if let audio = activePlaylist {
                HStack(spacing: 12) {
                    AudioTransport(playlist: audio)
                    TimelineScrubber(
                        position: coordinator.audioCurrentTime,
                        duration: coordinator.audioDuration,
                        width: 160
                    ) { coordinator.seekAudio(to: $0) }
                }
                .fixedSize()
            }
            trailingControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

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
                if let name = activePlaylist?.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            TransportButton(
                title: isExpanded ? "Collapse audio" : "Expand audio",
                systemImage: isExpanded ? "chevron.up" : "chevron.down",
                size: .chrome
            ) { isExpanded ? overlays.collapseAudioToCompact() : overlays.expandAudioToExtended() }

            TransportButton(title: "Close audio", systemImage: "xmark", size: .chrome) {
                overlays.closeAudioOverlay()
            }
        }
    }

}
