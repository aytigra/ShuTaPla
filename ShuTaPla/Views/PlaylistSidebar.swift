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

    // Inline rename: the playlist being edited and its draft text.
    @State private var renaming: Playlist?
    @State private var draftName = ""

    var body: some View {
        // One fetch per body evaluation, shared by the section and its empty state rather than
        // read twice. Deliberately not a `@Query`: a live query refaults every registered
        // `Playlist` on any store save, which re-rendered the whole Manager on each gallery
        // metadata fill. Reading `appState.playlists(ofType:)` registers `playlistsVersion`, so
        // this body re-runs only when the playlist set, its order, a name or a count changes.
        let playlists = appState.playlists(ofType: appState.managerScope)
        List {
            importingSection
            section(playlists)
        }
        .listStyle(.sidebar)
        .overlay { emptyOverlay(playlists) }
        .safeAreaInset(edge: .top) {
            AudioInlet()
        }
        // The Manager sidebar owns playlist deletion for every scope — visual and audio alike,
        // since both browse here. The player-mode audio overlay is a pure selector with no delete.
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(get: { appState.pendingConfirmation?.playlistToDelete != nil }, set: { if !$0 { appState.cancelConfirmation() } }),
            titleVisibility: .visible,
            presenting: appState.pendingConfirmation?.playlistToDelete
        ) { playlist in
            Button("Delete “\(playlist.name)”", role: .destructive) {
                appState.confirmConfirmation()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelConfirmation() }
        } message: { _ in
            Text("This removes the playlist from Shutapla. The files on disk are not touched.")
        }
    }

    // MARK: - Sections

    /// The placeholder shown when the active scope has no playlists.
    @ViewBuilder
    private func emptyOverlay(_ playlists: [Playlist]) -> some View {
        if playlists.isEmpty {
            let (icon, hint): (String, String) = switch appState.managerScope {
            case .image: ("photo.stack", "Add a folder of images.")
            case .video: ("film.stack", "Add a folder of videos.")
            case .audio: ("music.note.list", "Add a folder of audio files.")
            }
            ContentUnavailableView {
                Label("No \(appState.managerScope.displayName) Playlists", systemImage: icon)
            } description: {
                Text(hint)
            }
        }
    }

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
                text: $draftName,
                onCommit: { commitRename() },
                onCancel: { renaming = nil }
            )
        } else {
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
            .disabled(appState.deletingPlaylistIDs.contains(playlist.id))
            .listRowBackground(isSelectedRow(playlist) ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : nil)
            .contextMenu {
                Button("Rename") { beginRename(playlist) }
                Button("Delete", role: .destructive) { appState.requestPlaylistDelete(playlist) }
            }
        }
    }

    /// Whether `playlist` is the managed playlist, so its row reads as highlighted.
    private func isSelectedRow(_ playlist: Playlist) -> Bool {
        appState.managedPlaylist === playlist
    }

    // MARK: - Rename

    private func beginRename(_ playlist: Playlist) {
        draftName = playlist.name
        renaming = playlist
    }

    private func commitRename() {
        if let playlist = renaming {
            appState.rename(playlist, to: draftName)
        }
        renaming = nil
    }
}
