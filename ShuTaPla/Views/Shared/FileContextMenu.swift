//
//  FileContextMenu.swift
//  ShuTaPla
//
//  The per-file context menu shared by the Manager list/gallery and the player's
//  Visual Overlay. Rename, Show in Finder, and the video-only Remove Audio
//  item (with their ordering) are identical everywhere; the actions that differ by
//  surface — what Rename/Remove Audio/Delete target and which confirmation they
//  raise — are passed in as closures.
//

import SwiftUI

struct FileContextMenu: View {
    let file: PlaylistFile
    let playlist: Playlist
    let onRename: () -> Void
    let onRemoveAudio: () -> Void
    let onDelete: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Rename", action: onRename)
        Button("Show in Finder") { appState.revealInFinder(file) }
        if playlist.mediaType == .video {
            Button("Remove Audio", action: onRemoveAudio)
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }
}
