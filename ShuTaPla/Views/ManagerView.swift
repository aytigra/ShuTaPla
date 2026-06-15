//
//  ManagerView.swift
//  ShuTaPla
//
//  Manager-mode shell: a three-pane layout built on `NavigationSplitView` (the
//  playlists sidebar and the center file panel) plus a trailing `.inspector` for
//  the tag panel. Each region fills the full window height and is independently
//  resizable, and the split view remembers the widths the user sets.
//

import SwiftUI

struct ManagerView: View {
    @Environment(AppState.self) private var appState

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var managingTags = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PlaylistSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            PlaylistCenterView()
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $showInspector) {
                    TagSidebar(managingTags: $managingTags)
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 380)
                }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    // Entering management is meaningless with the panel hidden, so reveal it.
                    if !managingTags { showInspector = true }
                    managingTags.toggle()
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                        .symbolVariant(managingTags ? .fill : .none)
                }
                .disabled(appState.selectedPlaylist == nil)
                .help(managingTags ? "Edit selected files' tags" : "Manage playlist tags")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Toggle Tags", systemImage: "sidebar.right")
                }
                .help(showInspector ? "Hide tags" : "Show tags")
            }
        }
    }
}
