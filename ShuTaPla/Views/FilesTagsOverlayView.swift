//
//  FilesTagsOverlayView.swift
//  ShuTaPla
//
//  The Files & Tags overlay: a simplified, single-file surface that slides up from the
//  bottom over the player. Left: the playlist's tag filter (reusing `FilterBar`) above its
//  filtered file list — double-click to play that file and dismiss the overlay, with a
//  per-row rename / delete / reveal menu. Right: the tag editor (reusing `TagEditorView`)
//  targeting the currently
//  playing file only. Bulk multi-select tag editing stays in Manager mode.
//

import SwiftUI
import AppKit

struct FilesTagsOverlayView: View {
    let playlist: Playlist
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays

    @State private var renamingID: UUID?
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                fileColumn
                Divider()
                tagColumn.frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .playerOverlayPanel()
        // A click on empty chrome resigns the tag field so it can be unfocused
        // anywhere, not just by tabbing to another control.
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .alert(
            "Couldn't complete",
            isPresented: Binding(get: { appState.playerRenameError != nil }, set: { if !$0 { appState.playerRenameError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.playerRenameError = nil }
        } message: {
            Text(appState.playerRenameError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Files & Tags", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Spacer()
            Button { overlays.closeFilesTags() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - File column

    private var fileColumn: some View {
        VStack(spacing: 0) {
            // Above the list so the filter's floating tag dropdown overlays it.
            FilterBar(playlist: playlist)
                .zIndex(1)
            Divider()
            if appState.filteredFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The file column's empty state. A plain centered stack (not `ContentUnavailableView`,
    /// which lays itself out against the window and so jumps to screen center instead of
    /// riding the panel's slide-in) so it moves with the overlay's transition.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 40))
            Text("No Files")
                .font(.title3.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.filteredFiles) { file in
                        row(file)
                            .id(file.id)
                        Divider()
                    }
                }
            }
            // Open onto the file that's playing, so the list isn't scrolled to the top
            // away from the current file.
            .onAppear {
                if let id = coordinator.visualCurrentFile?.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ file: PlaylistFile) -> some View {
        FileRowView(
            file: file,
            playlist: playlist,
            isSelected: coordinator.visualCurrentFile?.id == file.id,
            isRenaming: renamingID == file.id,
            isStripping: false,
            draftName: $draftName,
            onCommitRename: { commitRename(file) },
            onCancelRename: { renamingID = nil }
        )
        // One tap gesture branching on the event's click count: a separate `count: 2`
        // gesture here would stack against the panel-wide single tap below, so a
        // double-click could lose a click to the background's resign-focus handler.
        // Double-click means "play this one": switch to it, resume if paused, and close
        // the overlay so playback continues unobstructed. A single click does nothing
        // (the panel tap still resigns the tag field).
        .onTapGesture {
            guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
            coordinator.playNow(playlist, file: file)
            overlays.closeFilesTags()
        }
        .contextMenu {
            FileContextMenu(
                file: file,
                playlist: playlist,
                onRename: { beginRename(file) },
                onRemoveAudio: { appState.requestAudioStrip([file]) },
                onDelete: { appState.requestPlayerDelete(file) }
            )
        }
    }

    // MARK: - Tag column

    @ViewBuilder
    private var tagColumn: some View {
        if let current = coordinator.visualCurrentFile {
            VStack(alignment: .leading, spacing: 0) {
                Text(current.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                Divider().padding(.top, 8)
                TagEditorView(playlist: playlist, files: [current], autoFocus: true)
                Spacer(minLength: 0)
            }
        } else {
            ContentUnavailableView("No File Playing", systemImage: "tag")
        }
    }

    // MARK: - Rename

    private func beginRename(_ file: PlaylistFile) {
        draftName = file.fileName
        renamingID = file.id
    }

    private func commitRename(_ file: PlaylistFile) {
        let name = draftName
        renamingID = nil
        Task { if let error = await appState.renameFile(file, to: name) { appState.playerRenameError = error } }
    }
}
