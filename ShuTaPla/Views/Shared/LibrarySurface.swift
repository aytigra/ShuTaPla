//
//  LibrarySurface.swift
//  ShuTaPla
//
//  The player-mode library surface: three columns — a single-type playlist selector,
//  the active playlist's filtered file list (topped by its `FilterBar`), and a tag editor
//  for the current file. It drives one playback channel, wired through a `LibraryContext`
//  that supplies the channel-specific slots and actions; the audio overlay and the
//  Visual Overlay both render their lower body from it. Shared `AppState` / coordinator
//  come from the environment, so the context carries only what differs between channels.
//

import SwiftUI
import SwiftData
import AppKit

/// The channel-specific wiring a `LibrarySurface` renders from. Everything that differs
/// between the audio channel and the visual channel — which playlists it lists, the
/// active playlist, its filtered files and current track, and the actions a row triggers.
struct LibraryContext {
    /// The one media type the selector lists — the channel's current type.
    let mediaType: MediaType
    /// The playlist the surface acts on (highlighted in the selector, source of the file list).
    let activePlaylist: Playlist?
    /// The active playlist's filtered, display-ordered file identifiers, resolved row-by-row.
    let fileIDs: [PersistentIdentifier]
    /// The current track, selected in the list and shown in the tag column.
    let currentFile: PlaylistFile?
    /// Bumped/changed when the file list should re-center on `currentFile` (a playlist switch).
    let scrollTrigger: AnyHashable
    /// Whether the tag editor grabs focus on appear (the visual overlay does; audio doesn't).
    let tagAutoFocus: Bool

    /// Choose a playlist in the selector — switches the channel to it.
    let onSelectPlaylist: (Playlist) -> Void
    /// The `+` footer — add a playlist from a folder.
    let onAddPlaylist: () -> Void
    /// Double-click a file — play it on this channel.
    let onPlayFile: (Playlist, PlaylistFile) -> Void
    /// Delete a file (move to Trash) from its row menu.
    let onDeleteFile: (PlaylistFile) -> Void
    /// Strip the audio track from a file; a no-op on channels where it doesn't apply.
    let onRemoveAudio: (PlaylistFile) -> Void
    /// Surface a rename failure on the channel's error alert.
    let onRenameError: (String) -> Void
}

struct LibrarySurface: View {
    let context: LibraryContext

    @Environment(AppState.self) private var appState
    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    @State private var fileRenamingID: UUID?
    @State private var fileDraftName = ""
    // A switch/re-center scroll for the file list, applied by `PagedList`. Set when the channel
    // asks to re-center (a playlist switch bumps `scrollTrigger`).
    @State private var fileScrollCommand: ScrollCommand?

    private var playlists: [Playlist] { allPlaylists.filter { $0.mediaType == context.mediaType } }

    /// The current track's index in the file list — where `PagedList` opens with no travel, and
    /// the row a re-center scroll reveals. `nil` when nothing is current or it is filtered out.
    private var fileTargetIndex: Int? {
        guard let pid = context.currentFile?.persistentModelID else { return nil }
        return context.fileIDs.firstIndex(of: pid)
    }

    var body: some View {
        HStack(spacing: 0) {
            playlistsColumn.frame(width: 240)
            Divider()
            fileColumn
            Divider()
            tagColumn.frame(width: 300)
        }
        // Switching playlists swaps the file list in place without remounting the surface, so an
        // abandoned rename draft for the old playlist would otherwise survive and re-activate when
        // that file scrolls back into view. Clear it when the active playlist changes.
        .onChange(of: context.activePlaylist?.id) { _, _ in
            fileRenamingID = nil
            fileDraftName = ""
        }
    }

    // MARK: - Playlists column

    private var playlistsColumn: some View {
        VStack(spacing: 0) {
            List {
                ForEach(playlists) { playlist in
                    playlistRow(playlist)
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No \(context.mediaType.displayName) Playlists", systemImage: "rectangle.stack")
                    } description: {
                        Text("Add a folder of \(context.mediaType.displayName.lowercased()) files.")
                    }
                }
            }

            Divider()
            HStack {
                Button { context.onAddPlaylist() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(appState.isAddingPlaylist)
                .help("Add a playlist from a folder")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        Button { context.onSelectPlaylist(playlist) } label: {
            HStack {
                Text(playlist.name).lineLimit(1)
                Spacer()
                if appState.deletingPlaylistIDs.contains(playlist.id) {
                    ProgressView().controlSize(.small).tint(.red)
                } else if appState.busyPlaylistIDs.contains(playlist.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(playlist.fileCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(context.activePlaylist === playlist ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : nil)
    }

    // MARK: - File column

    private var fileColumn: some View {
        VStack(spacing: 0) {
            // The channel playlist's own filter bar, editing its persisted filter directly.
            // Raised above the file list so its floating tag dropdown overlays the rows below.
            if let playlist = context.activePlaylist {
                FilterBar(playlist: playlist)
                    .zIndex(1)
            }
            Divider()
            if let playlist = context.activePlaylist, !context.fileIDs.isEmpty {
                fileList(playlist)
            } else {
                emptyFiles
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A plain centered stack (not `ContentUnavailableView`, which lays out against the
    /// window and jumps to screen center) so the empty state rides the overlay's slide-in.
    private var emptyFiles: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 40))
            Text(context.activePlaylist == nil ? "Nothing Playing" : "No Files")
                .font(.title3.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The shared `FileListSurface` in its overlay role — the current track is the selection (no
    /// separate playback-cursor glyph), a double-click plays the file. `FileListSurface` owns the
    /// `.id(playlist)` remount that reopens positioned on a switch; a re-selection of the active
    /// playlist re-bumps `scrollTrigger` (without changing the playlist) to re-center the current track.
    private func fileList(_ playlist: Playlist) -> some View {
        FileListSurface(
            ids: context.fileIDs,
            playlist: playlist,
            role: .overlay(currentID: context.currentFile?.id),
            targetIndex: fileTargetIndex,
            command: fileScrollCommand,
            renamingID: fileRenamingID,
            draftName: $fileDraftName,
            onTap: { file in
                guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
                context.onPlayFile(playlist, file)
            },
            onCommitRename: { commitFileRename($0) },
            onCancelRename: { fileRenamingID = nil },
            onRename: { fileDraftName = $0.fileName; fileRenamingID = $0.id },
            onRemoveAudio: { context.onRemoveAudio($0) },
            onDownload: { appState.downloadFiles([$0]) },
            onDelete: { context.onDeleteFile($0) }
        )
        .onChange(of: context.scrollTrigger) { _, trigger in
            guard let index = fileTargetIndex else { return }
            fileScrollCommand = ScrollCommand(index: index, mode: .jump, token: trigger)
        }
    }

    private func commitFileRename(_ file: PlaylistFile) {
        let name = fileDraftName
        fileRenamingID = nil
        Task { if let error = await appState.renameFile(file, to: name) { context.onRenameError(error) } }
    }

    // MARK: - Tag column

    @ViewBuilder
    private var tagColumn: some View {
        if let playlist = context.activePlaylist, let current = context.currentFile {
            VStack(alignment: .leading, spacing: 0) {
                Text(current.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                Divider().padding(.top, 8)
                TagEditorView(playlist: playlist, files: [current], autoFocus: context.tagAutoFocus)
                Spacer(minLength: 0)
            }
        } else {
            ContentUnavailableView("No File Playing", systemImage: "tag")
        }
    }
}
