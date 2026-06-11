//
//  TagSidebar.swift
//  ShuTaPla
//
//  The Manager-mode right panel: the filter controls (FilterBar) over the selected
//  playlist's tags, and the tag editor (TagEditorView) for the current file-list
//  selection. Shows a placeholder when no playlist is selected.
//

import SwiftUI

struct TagSidebar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let playlist = appState.selectedPlaylist {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FilterBar(playlist: playlist)
                    Divider()
                    TagEditorView(playlist: playlist, files: selectedFiles(in: playlist))
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Select a playlist to filter and tag.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The selected files within this playlist, in display order.
    private func selectedFiles(in playlist: Playlist) -> [PlaylistFile] {
        playlist.files
            .filter { appState.selectedFileIDs.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}
