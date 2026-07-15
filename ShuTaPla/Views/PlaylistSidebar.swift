//
//  PlaylistSidebar.swift
//  ShuTaPla
//
//  The Manager-mode left panel. Its sections follow the active scope — Video + Image
//  (visual) or Audio — with full management (create, rename inline, delete, reorder via
//  drag), and the audio transport inlet pinned at the top, parallel to either scope. Rows
//  are driven from a `@Query` sorted by `sortOrder` and filtered into sections in memory.
//

import SwiftUI
import SwiftData

struct PlaylistSidebar: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    // Inline rename: the playlist being edited and its draft text.
    @State private var renaming: Playlist?
    @State private var draftName = ""

    var body: some View {
        List {
            importingSection
            sections
        }
        .listStyle(.sidebar)
        .overlay { emptyOverlay }
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

    private var videoPlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .video } }
    private var imagePlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .image } }
    private var audioPlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .audio } }

    /// The single section for the active scope's media type.
    @ViewBuilder
    private var sections: some View {
        switch appState.managerScope {
        case .image: section(title: "Image", mediaType: .image)
        case .video: section(title: "Video", mediaType: .video)
        case .audio: section(title: "Audio", mediaType: .audio)
        }
    }

    /// The placeholder shown when the active scope has no playlists.
    @ViewBuilder
    private var emptyOverlay: some View {
        switch appState.managerScope {
        case .image where imagePlaylists.isEmpty:
            ContentUnavailableView {
                Label("No Image Playlists", systemImage: "photo.stack")
            } description: {
                Text("Add a folder of images.")
            }
        case .video where videoPlaylists.isEmpty:
            ContentUnavailableView {
                Label("No Video Playlists", systemImage: "film.stack")
            } description: {
                Text("Add a folder of videos.")
            }
        case .audio where audioPlaylists.isEmpty:
            ContentUnavailableView {
                Label("No Audio Playlists", systemImage: "music.note.list")
            } description: {
                Text("Add a folder of audio files.")
            }
        default:
            EmptyView()
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
                appState.manage(playlist)
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
                        Text("\(playlist.fileCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
