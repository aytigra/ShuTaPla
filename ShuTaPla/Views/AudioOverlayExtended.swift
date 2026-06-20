//
//  AudioOverlayExtended.swift
//  ShuTaPla
//
//  The extended audio overlay: the manager view for audio playlists, which never appear
//  in the main window's Manager mode. It keeps the compact transport at the top and adds
//  three columns — an audio-only playlists panel with full management (create, rename,
//  delete, reorder), the active playlist's filtered file list, and a tag editor for the
//  current track. It is exclusive with every other overlay and works during playback.
//

import SwiftUI
import SwiftData
import AppKit

struct AudioOverlayExtended: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays
    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    @State private var renamingID: UUID?
    @State private var draftName = ""
    @State private var fileRenamingID: UUID?
    @State private var fileDraftName = ""

    private var audioPlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .audio } }
    private var activePlaylist: Playlist? { appState.activeAudioPlaylist }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AudioOverlayCompact()
            Divider()
            HStack(spacing: 0) {
                playlistsColumn.frame(width: 240)
                Divider()
                fileColumn
                Divider()
                tagColumn.frame(width: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .playerOverlayPanel()
        .contentShape(Rectangle())
        .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(
                get: { appState.pendingPlaylistDelete?.mediaType == .audio },
                set: { if !$0 { appState.pendingPlaylistDelete = nil } }
            ),
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
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { appState.audioDeleteCandidate != nil },
                set: { if !$0 { appState.cancelAudioDelete() } }
            ),
            presenting: appState.audioDeleteCandidate
        ) { file in
            Button("Move to Trash", role: .destructive) { appState.confirmAudioDelete() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelAudioDelete() }
                .keyboardShortcut(.cancelAction)
        } message: { file in
            Text("“\(file.fileName)” is moved to the Trash and removed from this playlist.")
        }
        .alert(
            "Couldn't move to Trash",
            isPresented: Binding(get: { appState.audioDeleteError != nil }, set: { if !$0 { appState.audioDeleteError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.audioDeleteError = nil }
        } message: {
            Text(appState.audioDeleteError ?? "")
        }
        .alert(
            "Couldn't complete",
            isPresented: Binding(get: { appState.audioRenameError != nil }, set: { if !$0 { appState.audioRenameError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.audioRenameError = nil }
        } message: {
            Text(appState.audioRenameError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Audio", systemImage: "music.note.list")
                .font(.headline)
            Spacer()
            Button { overlays.closeAudioOverlay() } label: {
                Image(systemName: "chevron.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close audio overlay")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Playlists column

    private var playlistsColumn: some View {
        VStack(spacing: 0) {
            List {
                ForEach(audioPlaylists) { playlist in
                    playlistRow(playlist)
                }
                .onMove { offsets, destination in
                    appState.reorder(audioPlaylists, fromOffsets: offsets, toOffset: destination)
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if audioPlaylists.isEmpty {
                    ContentUnavailableView {
                        Label("No Audio Playlists", systemImage: "music.note.list")
                    } description: {
                        Text("Add a folder of audio files.")
                    }
                }
            }

            Divider()
            HStack {
                Button { appState.isImportingPlaylist = true } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(appState.isAddingPlaylist)
                .help("Add an audio playlist from a folder")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        if renamingID == playlist.id {
            RenameFileField(
                text: $draftName,
                onCommit: {
                    appState.rename(playlist, to: draftName)
                    renamingID = nil
                },
                onCancel: { renamingID = nil }
            )
        } else {
            Button { appState.selectAudioPlaylist(playlist) } label: {
                HStack {
                    Text(playlist.name).lineLimit(1)
                    Spacer()
                    if appState.deletingPlaylistIDs.contains(playlist.id) {
                        ProgressView().controlSize(.small).tint(.red)
                    } else if appState.busyPlaylistIDs.contains(playlist.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(playlist.files.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(activePlaylist === playlist ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : nil)
            .contextMenu {
                Button("Rename") { draftName = playlist.name; renamingID = playlist.id }
                Button("Delete", role: .destructive) { appState.pendingPlaylistDelete = playlist }
            }
        }
    }

    // MARK: - File column

    private var fileColumn: some View {
        VStack(spacing: 0) {
            AudioFilterBar().zIndex(1)
            Divider()
            if appState.audioFilteredFiles.isEmpty {
                emptyFiles
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFiles: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
            Text(activePlaylist == nil ? "No Audio Playing" : "No Files")
                .font(.title3.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.audioFilteredFiles) { file in
                        fileRow(file).id(file.id)
                        Divider()
                    }
                }
            }
            .onAppear {
                if let id = appState.currentAudioFile?.id { proxy.scrollTo(id, anchor: .center) }
            }
            // (Re-)selecting a playlist while the overlay is open switches the list in place,
            // so `onAppear` won't fire — re-center on the token instead, deferred a layout pass
            // so the just-switched playlist's rows exist for `scrollTo` to land on.
            .onChange(of: appState.audioScrollToken) { _, _ in
                guard let id = appState.currentAudioFile?.id else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: PlaylistFile) -> some View {
        if let playlist = activePlaylist {
            FileRowView(
                file: file,
                playlist: playlist,
                isSelected: appState.currentAudioFile?.id == file.id,
                isRenaming: fileRenamingID == file.id,
                isStripping: false,
                draftName: $fileDraftName,
                onCommitRename: { commitFileRename(file) },
                onCancelRename: { fileRenamingID = nil }
            )
            .onTapGesture {
                guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
                coordinator.playNow(playlist, file: file)
            }
            .contextMenu {
                FileContextMenu(
                    file: file,
                    playlist: playlist,
                    onRename: { fileDraftName = file.fileName; fileRenamingID = file.id },
                    onRemoveAudio: {},   // never shown for audio playlists
                    onDelete: { appState.requestAudioDelete(file) }
                )
            }
        }
    }

    private func commitFileRename(_ file: PlaylistFile) {
        let name = fileDraftName
        fileRenamingID = nil
        Task { if let error = await appState.renameFile(file, to: name) { appState.audioRenameError = error } }
    }

    // MARK: - Tag column

    @ViewBuilder
    private var tagColumn: some View {
        if let playlist = activePlaylist, let current = appState.currentAudioFile {
            VStack(alignment: .leading, spacing: 0) {
                Text(current.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                Divider().padding(.top, 8)
                TagEditorView(playlist: playlist, files: [current])
                Spacer(minLength: 0)
            }
        } else {
            ContentUnavailableView("No Track Playing", systemImage: "tag")
        }
    }
}
