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
        // Not one outer `ScrollView`: the filter, editor, and preview summary stay fixed while the
        // preview's name list owns the remaining height with its own scroll, so a long selection
        // scrolls internally instead of growing the sidebar.
        VStack(alignment: .leading, spacing: 0) {
            // Both dropdowns float downward over the siblings below them, so their draw order runs
            // top-to-bottom: the filter's dropdown must win over the editor, and the editor's over
            // the preview.
            FilterBar(playlist: playlist)
                .zIndex(2)
            Divider()

            // The read-only preview of what the editor is acting on — the file(s) still selected,
            // including any pushed out of the effective filter by an edit.
            ManagerSelectionPreview(playlist: playlist)
            Divider()

            TagEditorView(playlist: playlist, files: appState.selectedManagerFiles())
              .zIndex(1)
            Spacer(minLength: 0)
        }
    }
}
