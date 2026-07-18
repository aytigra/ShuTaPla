//
//  FileListRow.swift
//  ShuTaPla
//
//  One file row keyed by a file's `PersistentIdentifier`, the row `FileListSurface` builds for both the
//  Manager file list and the overlay file lists. A single *concrete* (non-generic) view: it resolves
//  the model inside its own body, draws `FileRowView` + its `Divider`, and applies the tap / context
//  menu itself. Resolving here rather than in the caller keeps each `PagedList` row a
//  single view and lets the row observe the model it draws.
//
//  The two surfaces differ only in data: `role` picks the selection semantics (Manager's independent
//  multi-selection vs. the overlay's single current track), and the actions arrive as plain
//  `(PlaylistFile) -> Void` closures — no generic content parameter.
//

import SwiftUI
import SwiftData

/// How a row derives its selection cues — the one thing that differs between the Manager list
/// (independent multi-selection plus the playback-cursor glyph) and the overlay lists (the current
/// track is the selection; no separate cursor glyph).
enum FileRowRole: Equatable {
    case manager
    case overlay(currentID: UUID?)
}

struct FileListRow: View {
    let id: PersistentIdentifier
    let playlist: Playlist
    let role: FileRowRole
    /// The id of the row currently being renamed on this surface, if any.
    let renamingID: UUID?
    @Binding var draftName: String
    let onTap: (PlaylistFile) -> Void
    let onCommitRename: (PlaylistFile) -> Void
    let onCancelRename: () -> Void
    let onRename: (PlaylistFile) -> Void
    let onRemoveAudio: (PlaylistFile) -> Void
    let onDownload: (PlaylistFile) -> Void
    let onDelete: (PlaylistFile) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        if let file = appState.file(for: id) {
            let cues = cues(for: file)
            VStack(spacing: 0) {
                FileRowView(
                    file: file,
                    playlist: playlist,
                    isSelected: cues.isSelected,
                    isCurrent: cues.isCurrent,
                    isRenaming: renamingID == file.id,
                    isStripping: appState.strippingFileIDs.contains(file.id),
                    draftName: $draftName,
                    onCommitRename: { onCommitRename(file) },
                    onCancelRename: onCancelRename
                )
                Divider()
            }
            // A single tap gesture branching on the event's click count lives in `onTap`;
            // stacking a `count: 2` gesture would delay the single click by the double-click
            // interval and make selection feel laggy.
            .onTapGesture { onTap(file) }
            .contextMenu {
                FileContextMenu(
                    file: file,
                    playlist: playlist,
                    onRename: { onRename(file) },
                    onRemoveAudio: { onRemoveAudio(file) },
                    onDownload: { onDownload(file) },
                    onDelete: { onDelete(file) }
                )
            }
        }
    }

    /// Selection highlight and playback-cursor glyph for this file, per surface. Reads
    /// `appState.managerSelection` inside the body so the row observes selection changes.
    private func cues(for file: PlaylistFile) -> (isSelected: Bool, isCurrent: Bool) {
        switch role {
        case .manager:
            return (appState.managerSelection.contains(file.id), file.id == playlist.currentFileID)
        case .overlay(let currentID):
            return (currentID == file.id, false)
        }
    }
}
