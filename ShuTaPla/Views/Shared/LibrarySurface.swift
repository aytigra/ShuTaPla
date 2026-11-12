//
//  LibrarySurface.swift
//  ShuTaPla
//
//  The player-mode library surface: three columns — a playlist selector grouped by media type,
//  the active playlist's filtered file list (topped by its `FilterStrip`), and a tag editor
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
    /// The media types whose playlists the selector lists, grouped by type in this order. A type
    /// with no playlists gets no group; the groups carry type headers only when there are several.
    let mediaTypes: [MediaType]
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
}

struct LibrarySurface: View {
    let context: LibraryContext

    @Environment(AppState.self) private var appState

    @State private var fileRenamingID: UUID?
    // A switch/re-center scroll for the file list, applied by `PagedList`. Set when the channel
    // asks to re-center (a playlist switch bumps `scrollTrigger`).
    @State private var fileScrollCommand: ScrollCommand?

    /// The current track's index in the file list — where `PagedList` opens with no travel, and
    /// the row a re-center scroll reveals. `nil` when nothing is current or it is filtered out.
    private var fileTargetIndex: Int? {
        guard let pid = context.currentFile?.persistentModelID else { return nil }
        return context.fileIDs.firstIndex(of: pid)
    }

    var body: some View {
        HStack(spacing: 0) {
            PlaylistSelector(
                mediaTypes: context.mediaTypes,
                activePlaylist: context.activePlaylist,
                onSelect: context.onSelectPlaylist,
                onAdd: context.onAddPlaylist
            )
            .frame(width: 240)
            Divider()
            fileColumn
            Divider()
            tagColumn.frame(width: 300)
        }
        // Switching playlists swaps the file list in place without remounting the surface, so an
        // open rename for the old playlist would otherwise survive and re-activate when that file
        // scrolls back into view. Clear it when the active playlist changes.
        .onChange(of: context.activePlaylist?.id) { _, _ in
            fileRenamingID = nil
        }
        // Hold one scoped-access session for the active playlist's folder so the list rows' metadata
        // reads append to a pre-resolved URL instead of resolving the bookmark per file.
        .browsingSession(for: context.activePlaylist, folderAccess: appState.folderAccess)
    }

    // MARK: - File column

    private var fileColumn: some View {
        VStack(spacing: 0) {
            // The channel playlist's own filter strip, editing its persisted filter directly, and
            // without the triage surfaces — those are entered from the Manager. Raised above the
            // file list so its dropdowns overlay the rows below.
            if let playlist = context.activePlaylist {
                FilterStrip(playlist: playlist, showsTriage: false)
                    .zIndex(1)
            }
            Divider()
            if let playlist = context.activePlaylist, !context.fileIDs.isEmpty {
                fileList(playlist)
            } else {
                CenteredPlaceholder(
                    context.activePlaylist == nil ? "Nothing Playing" : "No Files",
                    systemImage: "doc"
                )
            }
        }
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
            onCommitRename: commitFileRename(of:to:),
            onCancelRename: { fileRenamingID = nil },
            actions: FileActions(
                onTap: { file in
                    guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
                    context.onPlayFile(playlist, file)
                },
                onRename: { fileRenamingID = $0.id },
                onMove: { appState.requestMove([$0]) },
                onRemoveAudio: { appState.requestAudioStrip([$0]) },
                onDownload: { appState.downloadFiles([$0]) },
                onDelete: { appState.requestDelete([$0]) }
            )
        )
        .onChange(of: context.scrollTrigger) { _, trigger in
            guard let index = fileTargetIndex else { return }
            fileScrollCommand = ScrollCommand(index: index, mode: .jump, token: trigger)
        }
    }

    /// A field also commits when its row leaves the list (a rename started on another file, a
    /// prune), so it closes the rename only while it is still the open one.
    private func commitFileRename(of id: UUID, to name: String) {
        if fileRenamingID == id { fileRenamingID = nil }
        appState.commitRename(of: id, to: name)
    }

    // MARK: - Tag column

    @ViewBuilder
    private var tagColumn: some View {
        if let playlist = context.activePlaylist, let current = context.currentFile {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    FolderPathText(file: current, in: playlist)
                }
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

extension LibrarySurface {
    /// The playlist column, grouped by media type with a `+` footer.
    private struct PlaylistSelector: View {
        let mediaTypes: [MediaType]
        let activePlaylist: Playlist?
        let onSelect: (Playlist) -> Void
        let onAdd: () -> Void

        @Environment(AppState.self) private var appState

        var body: some View {
            // One fetch per evaluation, shared by the list and its empty state. Reading it registers
            // `AppState.playlistsVersion`, so a playlist change re-evaluates this view without the
            // file and tag columns; that version gate is why the list is a fetch rather than a `@Query`.
            // The closures `LibrarySurface` passes in are new on every parent pass, so this body
            // also re-runs with each one (every track change); the fetch is small enough to accept.
            let sections = appState.playlistSections(of: mediaTypes)
            VStack(spacing: 0) {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.playlists) { row($0) }
                        } header: {
                            if sections.count > 1 { Text(section.mediaType.displayName) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if sections.isEmpty {
                        NoPlaylistsPlaceholder(mediaTypes: mediaTypes)
                    }
                }

                Divider()
                HStack {
                    let addTitle = "Add Playlist"
                    Button { onAdd() } label: {
                        Label(addTitle, systemImage: "plus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .disabled(appState.isAddingPlaylist)
                    .help(addTitle)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }

        private func row(_ playlist: Playlist) -> some View {
            Button { onSelect(playlist) } label: {
                HStack {
                    Text(playlist.name).lineLimit(1)
                    Spacer()
                    PlaylistRowBadge(playlist: playlist)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.playlistWork.isDeleting(playlist.id))
            .listRowBackground(activePlaylist === playlist ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : nil)
        }
    }
}
