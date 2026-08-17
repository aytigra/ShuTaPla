//
//  FileGalleryCell.swift
//  ShuTaPla
//
//  One gallery tile keyed by a file's `PersistentIdentifier`, the cell `GalleryPagedList` builds for
//  the Manager gallery. The self-resolving twin of `FileListRow`: it resolves the model inside its
//  own body, draws `GalleryCell`, and applies the tap / context menu itself (`.fileActions`) — so
//  both surfaces take the same thing: an `id` plus a `FileActions`, nothing generic. The gallery is
//  Manager-only, so selection is the Manager's multi-selection and the playback cursor its
//  `currentFileID`.
//

import SwiftUI
import SwiftData

struct FileGalleryCell: View {
    let id: PersistentIdentifier
    let playlist: Playlist
    /// The id of the row currently being renamed on this surface, if any.
    let renamingID: UUID?
    @Binding var draftName: String
    let onCommitRename: (PlaylistFile) -> Void
    let onCancelRename: () -> Void
    let actions: FileActions

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
            .fileActions(actions, for: file, in: playlist)
        }
    }
}
