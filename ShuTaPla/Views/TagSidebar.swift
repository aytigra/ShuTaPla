//
//  TagSidebar.swift
//  ShuTaPla
//
//  The Manager-mode right panel, shown in one of two modes selected from the toolbar:
//  the default tag-editing mode (a preview of the current file-list selection over
//  TagEditorView for it) and a tag-management mode (PlaylistTagsView) for renaming or
//  removing tags across the whole playlist. Shows a placeholder when no playlist is
//  selected. Filtering is not here — it lives in the center strip, over the file list
//  it narrows.
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
                tagEditing(playlist)
            }
        } else {
            CenteredPlaceholder("Select a playlist to filter and tag.", systemImage: "tag")
        }
    }

    private func tagEditing(_ playlist: Playlist) -> some View {
        // Not one outer `ScrollView`: the editor and the preview summary stay fixed while the
        // preview's name list owns the remaining height with its own scroll, so a long selection
        // scrolls internally instead of growing the sidebar.
        VStack(alignment: .leading, spacing: 0) {
            // The read-only preview of what the editor is acting on — the file(s) still selected,
            // including any pushed out of the effective filter by an edit.
            ManagerSelectionPreview(playlist: playlist)
            Divider()

            // The editor's tag dropdown floats downward over whatever follows it.
            TagEditorView(playlist: playlist, files: appState.selectedManagerFiles())
                .zIndex(1)
            Spacer(minLength: 0)
        }
    }
}
