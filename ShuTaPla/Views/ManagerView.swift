//
//  ManagerView.swift
//  ShuTaPla
//
//  Manager-mode shell: a three-column layout (playlists, center file list, tag
//  panel) built on `HSplitView` with independently collapsible side panels.
//

import SwiftUI

struct ManagerView: View {
    @Environment(AppState.self) private var appState

    @State private var leftCollapsed = false
    @State private var rightCollapsed = false

    var body: some View {
        HSplitView {
            if !leftCollapsed {
                PlaylistSidebar()
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                    .transition(.move(edge: .leading))
            }

            PlaylistCenterView()
                .frame(minWidth: 360, maxWidth: .infinity)

            if !rightCollapsed {
                TagSidebar()
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { leftCollapsed.toggle() }
                } label: {
                    Label("Toggle Playlists", systemImage: "sidebar.left")
                }
                .help(leftCollapsed ? "Show playlists" : "Hide playlists")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { rightCollapsed.toggle() }
                } label: {
                    Label("Toggle Tags", systemImage: "sidebar.right")
                }
                .help(rightCollapsed ? "Show tags" : "Hide tags")
            }
        }
    }
}
