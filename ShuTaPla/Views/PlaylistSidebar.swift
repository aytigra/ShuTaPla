//
//  PlaylistSidebar.swift
//  ShuTaPla
//
//  The Manager-mode left panel: playlists grouped into Video and Image sections
//  with full management (create, rename inline, delete, reorder via drag) and a
//  collapsed Audio hint at the top. Rows are driven from a `@Query` sorted by
//  `sortOrder` and filtered into sections in memory.
//

import SwiftUI
import SwiftData

struct PlaylistSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(OverlayManager.self) private var overlays

    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    // Inline rename: the playlist being edited and its draft text.
    @State private var renaming: Playlist?
    @State private var draftName = ""

    var body: some View {
        List {
            audioHint

            importingSection

            section(title: "Video", mediaType: .video)
            section(title: "Image", mediaType: .image)
        }
        .listStyle(.sidebar)
        .overlay {
            if videoPlaylists.isEmpty && imagePlaylists.isEmpty {
                ContentUnavailableView {
                    Label("No Playlists", systemImage: "rectangle.stack")
                } description: {
                    Text("Add a folder of videos or images.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                Button {
                    appState.isImportingPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(appState.isAddingPlaylist)
                .help("Add a playlist from a folder")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
        // Video/image only: an audio playlist's delete confirmation is presented from the
        // extended audio overlay, so the two surfaces never both present on the shared state.
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(get: { appState.pendingPlaylistDelete.map { $0.mediaType != .audio } ?? false }, set: { if !$0 { appState.pendingPlaylistDelete = nil } }),
            titleVisibility: .visible,
            presenting: appState.pendingPlaylistDelete
        ) { playlist in
            Button("Delete “\(playlist.name)”", role: .destructive) {
                appState.pendingPlaylistDelete = nil
                Task { await appState.delete(playlist) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.pendingPlaylistDelete = nil }
        } message: { _ in
            Text("This removes the playlist from ShuTaPla. The files on disk are not touched.")
        }
    }

    // MARK: - Sections

    private var videoPlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .video } }
    private var imagePlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .image } }
    private var audioPlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .audio } }

    /// Transient rows for folders still being scanned, each with a spinner. They
    /// disappear once the finished playlist appears in its section.
    @ViewBuilder
    private var importingSection: some View {
        if !appState.importingPlaylists.isEmpty {
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

    @ViewBuilder
    private func section(title: String, mediaType: MediaType) -> some View {
        let playlists = allPlaylists.filter { $0.mediaType == mediaType }
        Section(title) {
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
                appState.select(playlist)
            } label: {
                HStack {
                    Text(playlist.name)
                        .lineLimit(1)
                    Spacer()
                    if appState.deletingPlaylistIDs.contains(playlist.id) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.red)
                    } else if appState.busyPlaylistIDs.contains(playlist.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("\(playlist.files.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.deletingPlaylistIDs.contains(playlist.id))
            .listRowBackground(appState.selectedPlaylist === playlist ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : nil)
            .contextMenu {
                Button("Rename") { beginRename(playlist) }
                Button("Delete", role: .destructive) { appState.pendingPlaylistDelete = playlist }
            }
        }
    }

    /// Collapsed Audio hint. Pressing it opens the extended audio overlay, where audio
    /// playlists are managed (they never appear in the Video/Image sections).
    private var audioHint: some View {
        Section {
            Button {
                overlays.expandAudioToExtended()
            } label: {
                Label {
                    HStack {
                        Text("Audio")
                        Spacer()
                        if !audioPlaylists.isEmpty {
                            Text("\(audioPlaylists.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                } icon: {
                    Image(systemName: "music.note.list")
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
