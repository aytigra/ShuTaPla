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

    private var playlists: [Playlist] { allPlaylists.filter { $0.mediaType == context.mediaType } }

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
            if context.fileIDs.isEmpty {
                emptyFiles
            } else {
                fileList
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

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // The lazy container resolves only on-screen identifiers, so a large list
                    // never materializes at once.
                    ForEach(context.fileIDs, id: \.self) { id in
                        // The `Group` keeps one view per element however the resolve goes (a
                        // just-fetched identifier resolves in practice).
                        Group {
                            if let file = appState.file(for: id) {
                                fileRow(file).id(file.id)
                                Divider()
                            }
                        }
                    }
                }
            }
            // The overlay slides in, so the rows may not be laid out when `onAppear` fires —
            // defer a layout pass so `scrollTo` has rows to find and the list opens centered.
            .onAppear {
                guard let id = context.currentFile?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
            // Switching playlists swaps the list in place, so `onAppear` won't fire — re-center
            // on the trigger instead, deferred a layout pass so the new rows exist for `scrollTo`.
            .onChange(of: context.scrollTrigger) { _, _ in
                guard let id = context.currentFile?.id else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: PlaylistFile) -> some View {
        if let playlist = context.activePlaylist {
            FileRowView(
                file: file,
                playlist: playlist,
                isSelected: context.currentFile?.id == file.id,
                // The overlay list already conveys the current file as the selection; the
                // playback-cursor glyph is the Manager's cue, where selection is independent.
                isCurrent: false,
                isRenaming: fileRenamingID == file.id,
                isStripping: appState.strippingFileIDs.contains(file.id),
                draftName: $fileDraftName,
                onCommitRename: { commitFileRename(file) },
                onCancelRename: { fileRenamingID = nil }
            )
            .onTapGesture {
                guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
                context.onPlayFile(playlist, file)
            }
            .contextMenu {
                FileContextMenu(
                    file: file,
                    playlist: playlist,
                    onRename: { fileDraftName = file.fileName; fileRenamingID = file.id },
                    onRemoveAudio: { context.onRemoveAudio(file) },
                    onDelete: { context.onDeleteFile(file) }
                )
            }
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
