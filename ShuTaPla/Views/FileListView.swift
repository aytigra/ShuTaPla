//
//  FileListView.swift
//  ShuTaPla
//
//  The Manager center file list: a `LazyVStack` of rows for the playlist's
//  playable files, with click / shift-click / cmd-click selection, double-click
//  to play, inline rename, and a per-row context menu. Skipped files are not
//  shown here (they surface under the Skipped service filter in Task 7). The
//  gallery view mode is a placeholder until Task 8.
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
        if playlist.preferences.viewMode == .gallery {
            galleryPlaceholder
        } else {
            list
        }
    }

    private var list: some View {
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
            Button("Delete", role: .destructive) { confirmDelete(deleteTargets(for: file)) }
        }
    }

    private var galleryPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Gallery view arrives in Task 8.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var visibleFiles: [PlaylistFile] {
        playlist.files
            .filter { !$0.isSkipped }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var selectedFiles: [PlaylistFile] {
        visibleFiles.filter { appState.selectedFileIDs.contains($0.id) }
    }

    /// Deleting a row that's part of the selection deletes the whole selection;
    /// deleting an unselected row deletes just it.
    private func deleteTargets(for file: PlaylistFile) -> [PlaylistFile] {
        appState.selectedFileIDs.contains(file.id) && selectedFiles.count > 1 ? selectedFiles : [file]
    }

    // MARK: - Selection

    private func handleClick(_ file: PlaylistFile) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let id = file.id

        if modifiers.contains(.command) {
            if appState.selectedFileIDs.contains(id) {
                appState.selectedFileIDs.remove(id)
            } else {
                appState.selectedFileIDs.insert(id)
                anchor = id
            }
        } else if modifiers.contains(.shift),
                  let anchor,
                  let lo = index(of: anchor),
                  let hi = index(of: id) {
            let range = lo <= hi ? lo...hi : hi...lo
            appState.selectedFileIDs.formUnion(visibleFiles[range].map(\.id))
        } else {
            appState.selectedFileIDs = [id]
            anchor = id
        }
    }

    private func index(of id: UUID) -> Int? {
        visibleFiles.firstIndex { $0.id == id }
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
