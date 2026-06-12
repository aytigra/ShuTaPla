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
import UniformTypeIdentifiers

struct PlaylistSidebar: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    @State private var isImporting = false
    @State private var pending: PendingPlaylist?
    @State private var errorMessage: String?
    @State private var isWorking = false

    // Inline rename: the playlist being edited and its draft text.
    @State private var renaming: Playlist?
    @State private var draftName = ""

    // Delete confirmation target.
    @State private var deleteCandidate: Playlist?

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
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
                .help("Add a playlist from a folder")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await add(url) } }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Choose a media type",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            ForEach(typeChoices(for: pending), id: \.self) { type in
                Button(label(for: type, in: pending)) {
                    appState.confirmPlaylist(pending, mediaType: type)
                    self.pending = nil
                }
            }
            Button("Cancel", role: .cancel) { self.pending = nil }
        } message: { pending in
            Text("“\(pending.name)” has a mix of media. Which type should this playlist be?")
        }
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible,
            presenting: deleteCandidate
        ) { playlist in
            Button("Delete “\(playlist.name)”", role: .destructive) {
                deleteCandidate = nil
                Task { await appState.delete(playlist) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("This removes the playlist from ShuTaPla. The files on disk are not touched.")
        }
        .alert("Couldn't add playlist", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = nil }
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
            .listRowBackground(appState.selectedPlaylist === playlist ? Color.accentColor.opacity(0.18) : nil)
            .contextMenu {
                Button("Rename") { beginRename(playlist) }
                Button("Delete", role: .destructive) { deleteCandidate = playlist }
            }
        }
    }

    /// Collapsed Audio hint. Selecting it will open the extended audio overlay
    /// where audio playlists are managed (Task 15).
    private var audioHint: some View {
        Section {
            Label {
                HStack {
                    Text("Audio")
                    Spacer()
                    if !audioPlaylists.isEmpty {
                        Text("\(audioPlaylists.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: "music.note.list")
            }
            .foregroundStyle(.secondary)
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

    // MARK: - Add flow (shared with WelcomeView's logic)

    private func add(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        switch await appState.addPlaylist(from: url) {
        case .created:
            break
        case .needsTypeChoice(let p):
            pending = p
        case .empty:
            errorMessage = "“\(url.lastPathComponent)” has no videos, images, or audio files."
        case .failed(let message):
            errorMessage = message
        }
    }

    private func typeChoices(for pending: PendingPlaylist) -> [MediaType] {
        pending.scan.counts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    private func label(for type: MediaType, in pending: PendingPlaylist) -> String {
        let count = pending.scan.counts[type] ?? 0
        let noun: String
        switch type {
        case .video: noun = "Video"
        case .image: noun = "Image"
        case .audio: noun = "Audio"
        }
        return "\(noun) (\(count))"
    }
}
