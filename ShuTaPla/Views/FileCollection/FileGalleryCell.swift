//
//  FileGalleryCell.swift
//  ShuTaPla
//
//  One gallery tile keyed by a file's `PersistentIdentifier`, the cell `GalleryPagedList` builds for
//  the Manager gallery. The self-resolving twin of `FileListRow`: it resolves the model inside its
//  own body, draws `GalleryCell`, and applies the tap / context menu itself — so both surfaces are
//  symmetric "give me an `id` plus action closures" cells. The gallery is Manager-only, so selection
//  is the Manager's multi-selection and the playback cursor its `currentFileID`.
//

import SwiftUI
import SwiftData

struct FileGalleryCell: View {
    let id: PersistentIdentifier
    let playlist: Playlist
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
            GalleryCell(
                file: file,
                playlist: playlist,
                // Reads `appState.managerSelection` inside the body so the cell observes selection changes.
                isSelected: appState.managerSelection.contains(file.id),
                isCurrent: file.id == playlist.currentFileID,
                isRenaming: renamingID == file.id,
                isStripping: appState.strippingFileIDs.contains(file.id),
                draftName: $draftName,
                onCommitRename: { onCommitRename(file) },
                onCancelRename: onCancelRename
            )
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
}
