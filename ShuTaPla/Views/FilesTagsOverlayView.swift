//
//  FilesTagsOverlayView.swift
//  ShuTaPla
//
//  The visual player's library overlay: it slides up from the bottom and renders the shared
//  `LibrarySurface` below a header — a single-type playlist selector, the active playlist's
//  filtered file list, and the tag editor for the current file. Double-click a file to play
//  it and dismiss; selecting a playlist switches the visual channel to it. Bulk multi-select
//  tag editing stays in Manager mode.
//

import SwiftUI
import AppKit

struct FilesTagsOverlayView: View {
    let playlist: Playlist
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LibrarySurface(context: visualContext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .playerOverlayPanel()
        // A click on empty chrome resigns the tag field so it can be unfocused
        // anywhere, not just by tabbing to another control.
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .alert(
            "Couldn't complete",
            isPresented: Binding(get: { appState.playerRenameError != nil }, set: { if !$0 { appState.playerRenameError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.playerRenameError = nil }
        } message: {
            Text(appState.playerRenameError ?? "")
        }
    }

    /// The visual channel's wiring for the shared library surface: lists the active type's
    /// playlists, switches the visual channel on select, and routes file actions to the
    /// player's delete / strip-audio / rename-error paths.
    private var visualContext: LibraryContext {
        let files = appState.visualChannelFiles
        return LibraryContext(
            mediaType: playlist.mediaType,
            activePlaylist: playlist,
            files: files,
            currentFile: appState.currentVisualFile(in: files),
            scrollTrigger: appState.scrollSelectionToken,
            tagAutoFocus: true,
            onSelectPlaylist: { appState.playOnVisualChannel($0) },
            onAddPlaylist: { appState.isImportingPlaylist = true },
            onPlayFile: { coordinator.playNow($0, startingAt: $1); overlays.closeFilesTags() },
            onDeleteFile: { appState.requestPlayerDelete($0) },
            onRemoveAudio: { appState.requestAudioStrip([$0]) },
            onRenameError: { appState.playerRenameError = $0 }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Files & Tags", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Spacer()
            Button { overlays.closeFilesTags() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
