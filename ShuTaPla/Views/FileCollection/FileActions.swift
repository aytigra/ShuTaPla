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
    /// `View.fileActions(_:for:)` for why the two clicks aren't separate gestures.
    let onTap: (PlaylistFile) -> Void
    let onRename: (PlaylistFile) -> Void
    let onMove: (PlaylistFile) -> Void
    let onRemoveAudio: (PlaylistFile) -> Void
    let onDownload: (PlaylistFile) -> Void
    let onDelete: (PlaylistFile) -> Void
}

extension View {
    /// Makes a file presentation clickable and gives it the per-file context menu — the pair
    /// `FileListRow` and `FileGalleryCell` both wear over whatever they draw.
    func fileActions(_ actions: FileActions, for file: PlaylistFile) -> some View {
        // A single tap gesture branching on the event's click count lives in `onTap`;
        // stacking a `count: 2` gesture would delay the single click by the double-click
        // interval and make selection feel laggy.
        onTapGesture { actions.onTap(file) }
            .contextMenu { FileContextMenu(file: file, actions: actions) }
    }
}

/// The per-file context menu. Rename, Show in Finder, Move to…, and the Remove Audio item (only
/// where `canRemoveAudio`) are identical everywhere; what the actions target is the surface's
/// business, carried in `actions`. The items that change the file on disk are disabled while it is
/// busy: its operation would be refused, and a disabled item shows that before the click. The check
/// reads the clicked file only; a busy file elsewhere in the targets reaches the request, which
/// refuses and reports it.
private struct FileContextMenu: View {
    let file: PlaylistFile
    let actions: FileActions

    @Environment(AppState.self) private var appState

    var body: some View {
        let busy = appState.isBusy(file)
        Button("Rename") { actions.onRename(file) }
            .disabled(busy)
        Button("Show in Finder") { appState.revealInFinder(file) }
        Button("Move to…") { actions.onMove(file) }
            .disabled(busy)
        if file.canRemoveAudio {
            Button("Remove Audio") { actions.onRemoveAudio(file) }
                .disabled(busy)
        }
        // Only when the file isn't already on disk — a local file has nothing to pull down.
        if file.cloudStatus != .local {
            Button("Download") { actions.onDownload(file) }
        }
        Divider()
        Button("Delete", role: .destructive) { actions.onDelete(file) }
            .disabled(busy)
    }
}
