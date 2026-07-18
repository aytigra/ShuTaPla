//
//  FileContextMenu.swift
//  ShuTaPla
//
//  The per-file context menu shared by the Manager list/gallery and the player's
//  Visual Overlay. Rename, Show in Finder, and the Remove Audio item (video-only, and
//  hidden for a skipped file, which is wrong-type and unplayable) are identical
//  everywhere; the actions that differ by surface — what Rename/Remove Audio/Delete
//  target and which confirmation they raise — are passed in as closures.
//

import SwiftUI

struct FileContextMenu: View {
    let file: PlaylistFile
    let playlist: Playlist
    let onRename: () -> Void
    let onRemoveAudio: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Rename", action: onRename)
        Button("Show in Finder") { appState.revealInFinder(file) }
        // Actions that only apply to a playable file. A skipped file is wrong-type for its
        // playlist, so none of these can act on it — only rename / reveal / download / delete do.
        if !file.isSkipped {
            if playlist.mediaType == .video {
                Button("Remove Audio", action: onRemoveAudio)
            }
        }
        // Only when the file isn't already on disk — a local file has nothing to pull down.
        if file.cloudStatus != .local {
            Button("Download", action: onDownload)
        }
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }
}
