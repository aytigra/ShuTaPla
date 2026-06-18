//
//  FileListView.swift
//  ShuTaPla
//
//  The Manager center file list: a divided `LazyVStack` of `FileRowView`s over the
//  playlist's filtered files. Selection, rename, scroll, and the context menu are
//  handled by the shared `FileCollectionView`; this names the list presentation and
//  supplies the row. The gallery presentation of the same files is `FileGalleryView`.
//

import SwiftUI

struct FileListView: View {
    let playlist: Playlist
    let confirmDelete: ([PlaylistFile]) -> Void
    let reportError: (String) -> Void

    var body: some View {
        FileCollectionView(
            playlist: playlist,
            layout: .list,
            confirmDelete: confirmDelete,
            reportError: reportError
        ) { config in
            FileRowView(
                file: config.file,
                playlist: config.playlist,
                isSelected: config.isSelected,
                isRenaming: config.isRenaming,
                isStripping: config.isStripping,
                draftName: config.draftName,
                onCommitRename: config.onCommitRename,
                onCancelRename: config.onCancelRename
            )
        }
    }
}
