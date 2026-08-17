//
//  FileActions.swift
//  ShuTaPla
//
//  What a file can be asked to do on a browsing surface, and the click / context menu that
//  ask it. Every surface that draws files — the Manager list, its gallery, both overlay
//  lists — wears the same interactions, so they live here once and travel as one value
//  rather than as five closures repeated down every layer between the owner and its rows.
//
//  What the actions *mean* still differs by surface (the Manager targets the whole
//  multi-selection and raises its own confirmations; the overlay acts on the one file), so
//  the owner supplies the closures and this file only decides how they are reached.
//

import SwiftUI

/// The per-file actions a browsing surface hands down to its rows and cells.
struct FileActions {
    /// A click on the file itself. The handler branches on the event's click count — see
    /// `View.fileActions(_:for:in:)` for why the two clicks aren't separate gestures.
    let onTap: (PlaylistFile) -> Void
    let onRename: (PlaylistFile) -> Void
    let onRemoveAudio: (PlaylistFile) -> Void
    let onDownload: (PlaylistFile) -> Void
    let onDelete: (PlaylistFile) -> Void
}

extension View {
    /// Makes a file presentation clickable and gives it the per-file context menu — the pair
    /// `FileListRow` and `FileGalleryCell` both wear over whatever they draw.
    func fileActions(_ actions: FileActions, for file: PlaylistFile, in playlist: Playlist) -> some View {
        // A single tap gesture branching on the event's click count lives in `onTap`;
        // stacking a `count: 2` gesture would delay the single click by the double-click
        // interval and make selection feel laggy.
        onTapGesture { actions.onTap(file) }
            .contextMenu { FileContextMenu(file: file, playlist: playlist, actions: actions) }
    }
}

/// The per-file context menu. Rename, Show in Finder, and the Remove Audio item (video-only,
/// and hidden for a skipped file, which is wrong-type and unplayable) are identical
/// everywhere; what the actions target is the surface's business, carried in `actions`.
private struct FileContextMenu: View {
    let file: PlaylistFile
    let playlist: Playlist
    let actions: FileActions

    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Rename") { actions.onRename(file) }
        Button("Show in Finder") { appState.revealInFinder(file) }
        // Actions that only apply to a playable file. A skipped file is wrong-type for its
        // playlist, so none of these can act on it — only rename / reveal / download / delete do.
        if !file.isSkipped, playlist.mediaType == .video {
            Button("Remove Audio") { actions.onRemoveAudio(file) }
        }
        // Only when the file isn't already on disk — a local file has nothing to pull down.
        if file.cloudStatus != .local {
            Button("Download") { actions.onDownload(file) }
        }
        Divider()
        Button("Delete", role: .destructive) { actions.onDelete(file) }
    }
}
