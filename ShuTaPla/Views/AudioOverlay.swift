//
//  AudioOverlay.swift
//  ShuTaPla
//
//  The player-mode audio overlay: a single layout with a compact and an expanded state. The
//  compact transport bar slides down from the top edge with the current track and its
//  controls; a chevron expands a lower section — an audio playlists selector, the active
//  playlist's filtered file list, and a tag editor for the current track. It drives the
//  coordinator's independent audio channel, so it coexists with the visual player.
//
//  The lower section is built from the same components as the visual player overlays
//  (`AudioTransport`, `FileRowView`, `FileContextMenu`, `AudioFilterBar`, `TagEditorView`).
//  Playlist creation lives behind the `+`; rename / delete / reorder live in Manager's audio
//  scope, so the playlists panel here is a pure selector — choosing one plays it immediately.
//

import SwiftUI
import SwiftData
import AppKit

struct AudioOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(OverlayManager.self) private var overlays
    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    @State private var fileRenamingID: UUID?
    @State private var fileDraftName = ""

    private var isExpanded: Bool { overlays.active.contains(.audioExtended) }
    private var audioPlaylists: [Playlist] { allPlaylists.filter { $0.mediaType == .audio } }
    private var activePlaylist: Playlist? { appState.activeAudioPlaylist }

    var body: some View {
        VStack(spacing: 0) {
            compactBar
            if isExpanded {
                Divider()
                lowerSection
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .playerOverlayPanel(opacity: isExpanded ? 1 : 0.9)
        // A click on the expanded panel's empty chrome resigns the tag field so it can be
        // unfocused anywhere, not just by tabbing away.
        .contentShape(Rectangle())
        .onTapGesture { if isExpanded { NSApp.keyWindow?.makeFirstResponder(nil) } }
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

    // MARK: - Compact bar

    private var compactBar: some View {
        // Equal flexible side columns pin the transport to the true center, so it holds its
        // place as the left filename changes width; the filename truncates within its column.
        HStack(spacing: 12) {
            trackInfo
                .frame(maxWidth: .infinity, alignment: .leading)
            // Anchored on the *active* audio playlist, not the loaded channel: Stop removes the
            // playlist from the channel but leaves it active, so the transport stays on screen to
            // restart it.
            if let audio = activePlaylist {
                HStack(spacing: 12) {
                    AudioTransport(playlist: audio)
                    scrubber(audio)
                }
                .fixedSize()
            }
            trailingControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var trackInfo: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.currentAudioFile?.fileName ?? "No track playing")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let name = activePlaylist?.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func scrubber(_ audio: Playlist) -> some View {
        HStack(spacing: 8) {
            Text(coordinator.audioCurrentTime.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { min(coordinator.audioCurrentTime, max(coordinator.audioDuration, 0.1)) },
                set: { coordinator.seek(audio, to: $0) }
            ), in: 0...max(coordinator.audioDuration, 0.1))
            .frame(width: 160)
            .disabled(coordinator.audioDuration <= 0)
            Text(coordinator.audioDuration.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            Button {
                isExpanded ? overlays.collapseAudioToCompact() : overlays.expandAudioToExtended()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.callout.weight(.semibold))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(ControlButtonStyle())
            .help(isExpanded ? "Collapse audio" : "Expand audio")

            Button { overlays.closeAudioOverlay() } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(ControlButtonStyle())
            .help("Close audio")
        }
    }

    // MARK: - Lower section

    private var lowerSection: some View {
        HStack(spacing: 0) {
            playlistsColumn.frame(width: 240)
            Divider()
            fileColumn
            Divider()
            tagColumn.frame(width: 300)
        }
    }

    // MARK: - Playlists column

    private var playlistsColumn: some View {
        VStack(spacing: 0) {
            List {
                ForEach(audioPlaylists) { playlist in
                    playlistRow(playlist)
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

    private func playlistRow(_ playlist: Playlist) -> some View {
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
