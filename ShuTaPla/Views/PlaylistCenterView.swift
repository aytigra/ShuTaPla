//
//  PlaylistCenterView.swift
//  ShuTaPla
//
//  The Manager center panel: a header (name, Play, Reshuffle, Update, view-mode
//  toggle), the tagging counter notices, and the file list. Owns the shared
//  delete confirmation and error alert used by the list's interactions.
//

import SwiftUI

struct PlaylistCenterView: View {
    @Environment(AppState.self) private var appState

    @State private var deleteCandidates: [PlaylistFile] = []
    @State private var errorMessage: String?
    @State private var isUpdating = false

    var body: some View {
        Group {
            if let playlist = appState.selectedPlaylist {
                VStack(spacing: 0) {
                    header(playlist)
                    Divider()
                    noticeBar(playlist)
                    if playlist.preferences.viewMode == .gallery {
                        FileGalleryView(
                            playlist: playlist,
                            confirmDelete: { deleteCandidates = $0 },
                            reportError: { errorMessage = $0 }
                        )
                    } else {
                        FileListView(
                            playlist: playlist,
                            confirmDelete: { deleteCandidates = $0 },
                            reportError: { errorMessage = $0 }
                        )
                    }
                }
            } else {
                ContentUnavailableView("Select a Playlist", systemImage: "rectangle.stack")
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !deleteCandidates.isEmpty }, set: { if !$0 { deleteCandidates = [] } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let targets = deleteCandidates
                deleteCandidates = []
                Task {
                    if let error = await appState.deleteFiles(targets) { errorMessage = error }
                }
            }
            Button("Cancel", role: .cancel) { deleteCandidates = [] }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var deleteTitle: String {
        deleteCandidates.count == 1
            ? "Move “\(deleteCandidates[0].fileName)” to the Trash?"
            : "Move \(deleteCandidates.count) files to the Trash?"
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Text(playlist.name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Spacer()

            Button {
                appState.beginPlayback(of: playlist)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!hasPlayableFiles(playlist))

            Button {
                appState.reshuffle(playlist)
            } label: {
                Label("Reshuffle", systemImage: "shuffle")
            }

            Button {
                Task {
                    isUpdating = true
                    await appState.update(playlist)
                    isUpdating = false
                }
            } label: {
                Label("Update", systemImage: "arrow.clockwise")
            }
            .disabled(isUpdating)

            Picker("View", selection: viewMode(playlist)) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.gallery)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func viewMode(_ playlist: Playlist) -> Binding<ViewMode> {
        Binding(
            get: { playlist.preferences.viewMode },
            set: { playlist.preferences.viewMode = $0 }
        )
    }

    private func hasPlayableFiles(_ playlist: Playlist) -> Bool {
        playlist.files.contains { !$0.isSkipped }
    }

    // MARK: - Counter notices

    /// Untagged / invalid-tagging / skipped counts. Each acts as a toggle for the
    /// matching service filter, which overrides the tag filter while active.
    @ViewBuilder
    private func noticeBar(_ playlist: Playlist) -> some View {
        let untagged = playlist.files.filter { !$0.isSkipped && $0.taggingStatus == .untagged }.count
        let invalid = playlist.files.filter { !$0.isSkipped && $0.taggingStatus == .invalid }.count
        let skipped = playlist.files.filter(\.isSkipped).count

        if untagged > 0 || invalid > 0 || skipped > 0 {
            HStack(spacing: 8) {
                if untagged > 0 { notice("\(untagged) untagged", systemImage: "tag.slash", filter: .untagged) }
                if invalid > 0 { notice("\(invalid) invalid tagging", systemImage: "exclamationmark.triangle", filter: .invalidTagging) }
                if skipped > 0 { notice("\(skipped) skipped", systemImage: "nosign", filter: .skipped) }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
        }
    }

    private func notice(_ text: String, systemImage: String, filter: ServiceFilter) -> some View {
        let isActive = appState.activeServiceFilter == filter
        return Button {
            appState.toggleServiceFilter(filter)
        } label: {
            Label(text, systemImage: systemImage)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(isActive ? Color.accentColor.opacity(0.22) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .help(isActive ? "Show all files" : "Show only these")
    }
}
