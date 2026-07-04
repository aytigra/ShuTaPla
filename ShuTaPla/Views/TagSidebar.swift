//
//  TagSidebar.swift
//  ShuTaPla
//
//  The Manager-mode right panel, shown in one of two modes selected from the toolbar:
//  the default filter-and-edit mode (FilterBar over the playlist's tags, plus
//  TagEditorView for the current file-list selection) and a tag-management mode
//  (PlaylistTagsView) for renaming or removing tags across the whole playlist. Shows
//  a placeholder when no playlist is selected.
//

import SwiftUI

struct TagSidebar: View {
    @Environment(AppState.self) private var appState

    @Binding var managingTags: Bool

    var body: some View {
        if let playlist = appState.managedPlaylist {
            if managingTags {
                PlaylistTagsView(playlist: playlist)
            } else {
                filterAndEdit(playlist)
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

    private func filterAndEdit(_ playlist: Playlist) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Above the editor so the filter's floating tag dropdown overlays it.
                FilterBar(playlist: playlist)
                    .zIndex(1)
                Divider()
                TagEditorView(playlist: playlist, files: appState.selectedManagerFiles())
                Spacer(minLength: 0)
            }
        }
    }
}
