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
    /// plays on select, and routes deletes/rename errors to the audio alerts the overlay hosts.
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
            onRemoveAudio: { _ in },
            onRenameError: { appState.audioRenameError = $0 }
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
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { appState.audioDeleteCandidate != nil },
                set: { if !$0 { appState.cancelAudioDelete() } }
            ),
            presenting: appState.audioDeleteCandidate
        ) { file in
            Button("Move to Trash", role: .destructive) { appState.confirmAudioDelete() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelAudioDelete() }
                .keyboardShortcut(.cancelAction)
        } message: { file in
            Text("“\(file.fileName)” is moved to the Trash and removed from this playlist.")
        }
        .alert(
            "Couldn't move to Trash",
            isPresented: Binding(get: { appState.audioDeleteError != nil }, set: { if !$0 { appState.audioDeleteError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.audioDeleteError = nil }
        } message: {
            Text(appState.audioDeleteError ?? "")
        }
        .alert(
            "Couldn't complete",
            isPresented: Binding(get: { appState.audioRenameError != nil }, set: { if !$0 { appState.audioRenameError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.audioRenameError = nil }
        } message: {
            Text(appState.audioRenameError ?? "")
        }
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
                    scrubber
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

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(coordinator.audioCurrentTime.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { coordinator.audioProgressFraction },
                set: { coordinator.seekAudio(toFraction: $0) }
            ), in: 0...1)
            .frame(width: 160)
            .disabled(!coordinator.audioIsSeekable)
            Text(coordinator.audioDuration.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            Button {
                isExpanded ? overlays.collapseAudioToCompact() : overlays.expandAudioToExtended()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.callout.weight(.semibold))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(ControlButtonStyle())
            .help(isExpanded ? "Collapse audio" : "Expand audio")

            Button { overlays.closeAudioOverlay() } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(ControlButtonStyle())
            .help("Close audio")
        }
    }

}
