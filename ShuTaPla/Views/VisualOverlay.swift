//
//  VisualOverlay.swift
//  ShuTaPla
//
//  The visual player's library overlay: it slides up from the bottom and renders the shared
//  `LibrarySurface` below a header — a selector of video and image playlists, the active playlist's
//  filtered file list, and the tag editor for the current file. Double-click a file to play
//  it and dismiss; selecting a playlist of either type switches the visual channel to it. Bulk multi-select
//  tag editing stays in Manager mode.
//

import SwiftUI
import AppKit

struct VisualOverlay: View {
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
    }

    /// The visual channel's wiring for the shared library surface: lists both visual types'
    /// playlists, switches the visual channel on select, and routes file actions to the
    /// player's delete / strip-audio paths.
    private var visualContext: LibraryContext {
        LibraryContext(
            mediaTypes: [.video, .image],
            activePlaylist: playlist,
            fileIDs: appState.visualChannelFileIDs,
            currentFile: appState.currentVisualFile,
            scrollTrigger: appState.scrollSelectionToken,
            tagAutoFocus: overlays.visualOverlayFocusesTag,
            onSelectPlaylist: { appState.playOnVisualChannel($0) },
            onAddPlaylist: { appState.folderPick = .addPlaylist },
            onPlayFile: { coordinator.playNow($0, startingAt: $1); overlays.closeVisualOverlay() }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Files & Tags", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Spacer()
            Button { overlays.closeVisualOverlay() } label: {
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
