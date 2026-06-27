//
//  PlaylistCenterView.swift
//  ShuTaPla
//
//  The Manager center panel for the active scope: the tagging counter notices and the
//  file list. The playlist's name, Play, Reshuffle, and view-mode toggle live in the
//  Manager toolbar. Owns the shared delete, remove-audio, and error confirmations used
//  by the list's interactions.
//

import SwiftUI
import SwiftData

struct PlaylistCenterView: View {
    @Environment(AppState.self) private var appState

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let playlist = appState.managedPlaylist {
                center(playlist)
            } else {
                placeholder
            }
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { !appState.pendingManagerDelete.isEmpty },
                set: { if !$0 { appState.cancelManagerDelete() } }
            )
        ) {
            Button("Move to Trash", role: .destructive) { appState.confirmManagerDelete() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelManagerDelete() }
                .keyboardShortcut(.cancelAction)
        }
        .alert(
            audioStripTitle,
            isPresented: Binding(
                get: { !appState.pendingAudioStrip.isEmpty },
                set: { if !$0 { appState.cancelAudioStrip() } }
            )
        ) {
            Button("Remove Audio", role: .destructive) { appState.confirmAudioStrip() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelAudioStrip() }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("The original is moved to the Trash.")
        }
        .alert(
            "Couldn't remove audio",
            isPresented: Binding(get: { appState.audioStripError != nil }, set: { if !$0 { appState.audioStripError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.audioStripError = nil }
        } message: {
            Text(appState.audioStripError ?? "")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Couldn't move to Trash",
            isPresented: Binding(get: { appState.managerDeleteError != nil }, set: { if !$0 { appState.managerDeleteError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.managerDeleteError = nil }
        } message: {
            Text(appState.managerDeleteError ?? "")
        }
    }

    private var deleteTitle: String {
        let files = appState.pendingManagerDelete
        return files.count.pluralized(
            one: "Move “\(files[0].fileName)” to the Trash?",
            many: "Move \(files.count) files to the Trash?"
        )
    }

    private var audioStripTitle: String {
        let files = appState.pendingAudioStrip
        return files.count.pluralized(
            one: "Remove the audio from “\(files[0].fileName)”?",
            many: "Remove the audio from \(files.count) files?"
        )
    }

    // MARK: - Center

    /// The managed playlist's center: notices over its file list. Visual playlists offer the
    /// gallery presentation; audio has no gallery, so it is always the list.
    @ViewBuilder
    private func center(_ playlist: Playlist) -> some View {
        VStack(spacing: 0) {
            noticeBar(playlist)
            if playlist.mediaType != .audio, playlist.preferences.viewMode == .gallery {
                FileGalleryView(
                    playlist: playlist,
                    confirmDelete: { appState.requestManagerDelete($0) },
                    reportError: { errorMessage = $0 }
                )
            } else {
                FileListView(
                    playlist: playlist,
                    confirmDelete: { appState.requestManagerDelete($0) },
                    reportError: { errorMessage = $0 }
                )
            }
        }
    }

    /// Shown when no playlist is managed in the current scope.
    private var placeholder: some View {
        ContentUnavailableView("Select a Playlist", systemImage: "rectangle.stack")
    }

    // MARK: - Counter notices

    /// Untagged / invalid-tagging / skipped counts. Each acts as a toggle for the
    /// matching service filter, which overrides the tag filter while active.
    @ViewBuilder
    private func noticeBar(_ playlist: Playlist) -> some View {
        let _ = appState.sequenceVersion   // re-derive the counts when membership or triage changes
        let (untagged, invalid, skipped) = playlist.modelContext?.serviceFilterCounts(for: playlist) ?? (0, 0, 0)

        if untagged > 0 || invalid > 0 || skipped > 0 {
            HStack(spacing: 8) {
                if untagged > 0 { notice("\(untagged) untagged", filter: .untagged, on: playlist) }
                if invalid > 0 { notice("\(invalid) invalid tagging", filter: .invalidTagging, on: playlist) }
                if skipped > 0 { notice("\(skipped) skipped", filter: .skipped, on: playlist) }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
        }
    }

    private func notice(_ text: String, filter: ServiceFilter, on playlist: Playlist) -> some View {
        let isActive = playlist.filterState.serviceFilter == filter
        return Button {
            appState.toggleServiceFilter(filter, on: playlist)
        } label: {
            Label(text, systemImage: filter.systemImage)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isActive ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .help(isActive ? "Show all files" : "Show only these")
    }
}
