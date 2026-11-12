//
//  PlaylistSidebar.swift
//  ShuTaPla
//
//  The Manager-mode left panel. Its section follows the active scope — Video, Image or
//  Audio — with full management (create, rename inline, delete, reorder via drag), and the
//  audio transport inlet pinned at the top, parallel to either scope.
//

import SwiftUI

struct PlaylistSidebar: View {
    @Environment(AppState.self) private var appState

    // Inline rename: the playlist being edited.
    @State private var renaming: Playlist?

    var body: some View {
        // One fetch per body evaluation, shared by the section and its empty state rather than
        // read twice. Reading it registers `AppState.playlistsVersion` — the gate that decides
        // when this body re-runs, and why the list is a fetch rather than a `@Query`.
        let playlists = appState.playlists(ofType: appState.managerScope)
        List {
            importingSection
            section(playlists)
        }
        .listStyle(.sidebar)
        .overlay {
            if playlists.isEmpty {
                NoPlaylistsPlaceholder(mediaTypes: [appState.managerScope])
            }
        }
        .safeAreaInset(edge: .top) {
            AudioInlet()
        }
    }

    // MARK: - Sections

    /// Transient rows for folders still being scanned, each with a spinner. They
    /// disappear once the finished playlist appears in its section.
    @ViewBuilder
    private var importingSection: some View {
        if appState.importingPlaylists.isNotEmpty {
            Section {
                ForEach(appState.importingPlaylists) { importing in
                    HStack {
                        Text(importing.name)
                            .lineLimit(1)
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ playlists: [Playlist]) -> some View {
        Section(appState.managerScope.displayName) {
            ForEach(playlists) { playlist in
                row(playlist)
            }
            .onMove { offsets, destination in
                appState.reorder(playlists, fromOffsets: offsets, toOffset: destination)
            }
        }
    }

    /// A single selectable playlist row, with inline rename when active.
    @ViewBuilder
    private func row(_ playlist: Playlist) -> some View {
        if renaming === playlist {
            RenameFileField(
                name: playlist.name,
                onCommit: { commitRename(playlist, to: $0) },
                onCancel: { renaming = nil }
            )
        } else {
            let deleting = appState.playlistWork.isDeleting(playlist.id)
            Button {
                appState.manage(playlist)
            } label: {
                HStack {
                    Text(playlist.name)
                        .lineLimit(1)
                    Spacer()
                    PlaylistRowBadge(playlist: playlist)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(deleting)
            .listRowBackground(isSelectedRow(playlist) ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : nil)
            // The Manager sidebar owns playlist deletion for every scope — visual and audio alike,
            // since both browse here. The player-mode audio overlay is a pure selector with no delete.
            // A rename committed after the delete ends would write to a destroyed playlist.
            .contextMenu {
                Group {
                    Button("Rename") { beginRename(playlist) }
                    Button("Delete", role: .destructive) { appState.requestPlaylistDelete(playlist) }
                }
                .disabled(deleting)
            }
        }
    }

    /// Whether `playlist` is the managed playlist, so its row reads as highlighted.
    private func isSelectedRow(_ playlist: Playlist) -> Bool {
        appState.managedPlaylist === playlist
    }

    // MARK: - Rename

    private func beginRename(_ playlist: Playlist) {
        renaming = playlist
    }

    /// A field also commits when its row leaves the list (a rename started on another playlist),
    /// so it closes the rename only while it is still the open one.
    private func commitRename(_ playlist: Playlist, to name: String) {
        if renaming === playlist { renaming = nil }
        appState.rename(playlist, to: name)
    }
}
