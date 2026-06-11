//
//  FileListView.swift
//  ShuTaPla
//
//  The Manager center file list: a `LazyVStack` of rows for the playlist's
//  filtered files (`AppState.filteredFiles`), with click / shift-click / cmd-click
//  selection, double-click to play, inline rename, and a per-row context menu.
//  The active tag or service filter decides what appears here. The gallery
//  presentation of the same files lives in `FileGalleryView`.
//

import SwiftUI
import AppKit

struct FileListView: View {
    let playlist: Playlist
    let confirmDelete: ([PlaylistFile]) -> Void
    let reportError: (String) -> Void

    @Environment(AppState.self) private var appState

    @State private var anchor: UUID?
    @State private var renamingID: UUID?
    @State private var draftName = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleFiles) { file in
                    row(file)
                    Divider()
                }
            }
        }
        .overlay {
            if visibleFiles.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc")
            }
        }
    }

    private func row(_ file: PlaylistFile) -> some View {
        FileRowView(
            file: file,
            isSelected: appState.selectedFileIDs.contains(file.id),
            isRenaming: renamingID == file.id,
            draftName: $draftName,
            onCommitRename: { commitRename(file) },
            onCancelRename: { renamingID = nil }
        )
        .onTapGesture(count: 2) { appState.beginPlayback(of: playlist, startingAt: file) }
        .onTapGesture { handleClick(file) }
        .contextMenu {
            Button("Rename") { beginRename(file) }
            Button("Show in Finder") { appState.revealInFinder(file) }
            Divider()
            Button("Delete", role: .destructive) {
                confirmDelete(FileSelection.deleteTargets(for: file, selection: appState.selectedFileIDs, visible: visibleFiles))
            }
        }
    }

    // MARK: - Data

    /// The filtered, sorted files for the selected playlist, cached on `AppState`
    /// and kept in sync with the tag/service filter.
    private var visibleFiles: [PlaylistFile] {
        appState.filteredFiles
    }

    // MARK: - Selection

    private func handleClick(_ file: PlaylistFile) {
        FileSelection.apply(
            click: file.id,
            modifiers: NSEvent.modifierFlags,
            in: visibleFiles,
            selection: &appState.selectedFileIDs,
            anchor: &anchor
        )
    }

    // MARK: - Rename

    private func beginRename(_ file: PlaylistFile) {
        draftName = file.fileName
        renamingID = file.id
    }

    private func commitRename(_ file: PlaylistFile) {
        let name = draftName
        renamingID = nil
        Task {
            if let error = await appState.renameFile(file, to: name) {
                reportError(error)
            }
        }
    }
}
