//
//  ManagerView.swift
//  ShuTaPla
//
//  Manager-mode shell: a three-pane layout built on `NavigationSplitView` (the
//  playlists sidebar and the center file panel) plus a trailing `.inspector` for
//  the tag panel. Each region fills the full window height and is independently
//  resizable, and the split view remembers the widths the user sets.
//
//  The toolbar consolidates the Manager's controls into the single window toolbar (the only
//  place items survive a column collapsing). SwiftUI aligns the leading `navigation` section
//  above the sidebar — it carries the scope tabs (which double as the sidebar's collapse/expand
//  control) and New Playlist. The trailing section carries the scope-dependent playlist actions
//  and, after a `ToolbarSpacer` break, the tag controls; the window title sits between them.
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
                // The scope tabs are the sidebar's collapse/expand control, so the automatic
                // sidebar-toggle button is suppressed.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            PlaylistCenterView()
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(appState.managerPlaylist?.name ?? "ShuTaPla")
                .inspector(isPresented: $showInspector) {
                    TagSidebar(managingTags: $managingTags)
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 380)
                }
        }
        .toolbar { toolbarContent }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading, above the sidebar: scope tabs, then New Playlist pushed toward the sidebar's
        // trailing edge. Declared on the window toolbar so they persist when the sidebar narrows
        // or collapses (items on the sidebar column itself overflow and then vanish with it).
        ToolbarItemGroup(placement: .navigation) {
            scopeTab(.visual, "Visual", systemImage: "rectangle.stack")
            scopeTab(.audio, "Audio", systemImage: "music.note")
        }
        ToolbarSpacer(.flexible, placement: .navigation)
        ToolbarItem(placement: .navigation) {
            Button {
                appState.isImportingPlaylist = true
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
            .disabled(appState.isAddingPlaylist)
            .help("Add a playlist from a folder")
        }

        // Trailing: the playlist actions, a fixed-gap break, then the tag controls — the section
        // grouping macOS supports (it has no per-pane separator for the inspector).
        ToolbarItemGroup(placement: .primaryAction) {
            detailActions
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                // Entering management is meaningless with the panel hidden, so reveal it.
                if !managingTags { showInspector = true }
                managingTags.toggle()
            } label: {
                Label("Manage Tags", systemImage: "tag")
                    .symbolVariant(managingTags ? .fill : .none)
            }
            .disabled(appState.managerPlaylist == nil)
            .help(managingTags ? "Edit selected files' tags" : "Manage playlist tags")

            Button {
                showInspector.toggle()
            } label: {
                Label("Toggle Tags", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide tags" : "Show tags")
        }
    }

    /// One scope tab. Switching scope is a view-only change — it never starts, stops, or loads
    /// a channel. The tab also drives the sidebar: clicking the active scope collapses the left
    /// panel; clicking either tab while collapsed expands it and selects that scope.
    private func scopeTab(_ scope: ManagerScope, _ title: String, systemImage: String) -> some View {
        let collapsed = columnVisibility == .detailOnly
        let isActive = appState.managerScope == scope && !collapsed
        return Button {
            if collapsed {
                appState.managerScope = scope
                columnVisibility = .all
            } else if appState.managerScope == scope {
                columnVisibility = .detailOnly
            } else {
                appState.managerScope = scope
            }
        } label: {
            Label(title, systemImage: systemImage)
                .symbolVariant(isActive ? .fill : .none)
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .help(title)
    }

    /// The active scope's playlist actions: visual gets Play · Reshuffle · List/Gallery, audio
    /// gets Reshuffle. Both get the placeholder Settings button. Empty when nothing is selected.
    @ViewBuilder
    private var detailActions: some View {
        switch appState.managerScope {
        case .visual:
            if let playlist = appState.selectedPlaylist {
                visualActions(playlist)
            }
        case .audio:
            if let playlist = appState.activeAudioPlaylist {
                audioActions(playlist)
            }
        }
    }

    @ViewBuilder
    private func visualActions(_ playlist: Playlist) -> some View {
        @Bindable var playlist = playlist

        Button {
            appState.beginPlayback(of: playlist)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(!playlist.files.contains { !$0.isSkipped })
        .help("Play")

        Button {
            appState.reshuffle(playlist)
        } label: {
            Label("Reshuffle", systemImage: "shuffle")
        }
        .help("Reshuffle")

        Picker("View", selection: $playlist.preferences.viewMode) {
            Image(systemName: "list.bullet").tag(ViewMode.list)
            Image(systemName: "square.grid.2x2").tag(ViewMode.gallery)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("List or gallery")

        settingsButton
    }

    @ViewBuilder
    private func audioActions(_ playlist: Playlist) -> some View {
        Button {
            appState.reshuffle(playlist)
        } label: {
            Label("Reshuffle", systemImage: "shuffle")
        }
        .help("Reshuffle")

        settingsButton
    }

    /// Per-playlist settings — a placeholder affordance, disabled until the settings surface
    /// exists.
    private var settingsButton: some View {
        Button {
        } label: {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
        .disabled(true)
        .help("Playlist settings")
    }
}
