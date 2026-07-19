//
//  FileListSurface.swift
//  ShuTaPla
//
//  The windowed file list shared by the Manager's list presentation and both overlay file lists: a
//  `PagedList` of `FileListRow`s that sizes from the id count alone, opens at `targetIndex` with no
//  travel, and is driven onward by `command`. It owns the one subtle bit both surfaces need — the
//  `.id(playlist)` remount that reopens the list already positioned on a playlist switch (the
//  `openInitial` path) rather than repositioning a still-mounted list against just-swapped content.
//
//  The two surfaces differ only in what they feed it: `role` picks the selection semantics (Manager's
//  independent multi-selection vs. the overlay's single current track), and the row actions arrive as
//  plain `(PlaylistFile) -> Void` closures. Each owner computes its own `command` (the Manager's
//  `routeScroll`, the overlay's `scrollTrigger`) and passes it in.
//

import SwiftUI
import SwiftData

struct FileListSurface: View {
    let ids: [PersistentIdentifier]
    let playlist: Playlist
    let role: FileRowRole
    /// The id index to open on with no travel (the current file), or nil to open at the top.
    let targetIndex: Int?
    /// A later scroll to apply when it changes; nil issues nothing.
    let command: ScrollCommand?
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

    var body: some View {
        PagedList(
            count: ids.count,
            rowHeight: AppConstants.fileListRowHeight,
            initialTarget: targetIndex,
            command: command
        ) { index in
            if ids.indices.contains(index) {
                FileListRow(
                    id: ids[index],
                    playlist: playlist,
                    role: role,
                    renamingID: renamingID,
                    draftName: $draftName,
                    onTap: onTap,
                    onCommitRename: onCommitRename,
                    onCancelRename: onCancelRename,
                    onRename: onRename,
                    onRemoveAudio: onRemoveAudio,
                    onDownload: onDownload,
                    onDelete: onDelete
                )
            }
        }
        // A playlist switch discards and rebuilds the list so it opens already positioned on the new
        // current file (the `openInitial` path); `command` drives same-playlist re-center and keyboard
        // reveal on the still-mounted list.
        .id(playlist.persistentModelID)
    }
}
