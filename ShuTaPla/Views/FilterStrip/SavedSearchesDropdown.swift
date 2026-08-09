//
//  SavedSearchesDropdown.swift
//  ShuTaPla
//
//  The `Searches` list: picking and ordering only, since a saved search is edited by editing the
//  filter it is applied to. Each row is the search's name over its lists as a `FilterSummaryLine` —
//  names need not be unique, so the tags are what tell two rows apart — with the reorder pair and a
//  delete that asks first, as the expanded strip's own delete does.
//
//  It hangs from the `Searches` button as an overlay over the file list rather than in a popover of
//  its own, so it spans the strip's width and survives the delete confirmation being raised over it.
//  Closing on a click elsewhere is what a popover would have given for free: `ClickOutsideMonitor`
//  supplies it, told how tall the row above is so a click back on `Searches` still toggles.
//

import SwiftUI

struct SavedSearchesDropdown: View {
    let playlist: Playlist
    /// The height of the strip row the panel hangs from, which clicks may land on without closing it.
    let anchorHeight: CGFloat
    /// Closes the dropdown — applying a search, or clicking away from it, leaves nothing to pick.
    let onPick: () -> Void

    @Environment(AppState.self) private var appState

    /// The rows' own height, so the panel can stop growing and scroll instead. Measured rather than
    /// counted: an `.overlay` proposes the collapsed strip's height, which a `ScrollView` would take
    /// literally and shrink to, while the rows inside it are free to be whatever two lines need.
    @State private var contentHeight: CGFloat = 0

    /// Roughly six rows — past that the panel is running down over the file list it filters.
    private static let maximumHeight: CGFloat = 260

    private var searches: [SavedSearch] { playlist.sortedSavedSearches }

    var body: some View {
        ScrollView {
            list
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, Self.maximumHeight))
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity)
        // Opaque rather than a material: it sits over the file list, and the thumbnails behind it
        // read straight through anything translucent. Square, unlike the suggestion dropdown: this
        // one spans the strip's full width, and its rows are highlighted edge to edge — a corner
        // radius would be carved out of the top and bottom row's highlight rather than read as the
        // panel's own shape.
        .floatingPanel(Color(nsColor: .controlBackgroundColor), cornerRadius: 0)
        .background(ClickOutsideMonitor(anchorHeight: anchorHeight, onOutside: onPick))
    }

    private var list: some View {
        VStack(spacing: 0) {
            if searches.isEmpty {
                Text("No saved searches yet. Set a filter, name it, and press Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(searches) { search in
                    row(search)
                    if search !== searches.last { Divider() }
                }
            }
        }
    }

    private func row(_ search: SavedSearch) -> some View {
        HStack(spacing: 8) {
            Button { apply(search) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(search.name)
                        .lineLimit(1)
                    if let filter = search.filter {
                        FilterSummaryLine(filter: filter)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            move(search, by: -1, systemImage: "chevron.up", help: "Move up")
            move(search, by: 1, systemImage: "chevron.down", help: "Move down")

            Button(role: .destructive) { appState.requestSavedSearchDelete(search) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The system's unfocused-list gray, not the accent wash every other list uses: the rows here
        // are mostly accent-tinted pills, and a blue highlight behind them reads as one blur.
        .background(isActive(search) ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
    }

    private func move(_ search: SavedSearch, by offset: Int, systemImage: String, help: String) -> some View {
        Button { appState.moveSavedSearch(search, by: offset, on: playlist) } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .disabled(!searches.indices.contains((searches.firstIndex { $0 === search } ?? 0) + offset))
        .help(help)
    }

    private func isActive(_ search: SavedSearch) -> Bool {
        playlist.activeSavedSearch === search
    }

    private func apply(_ search: SavedSearch) {
        appState.applySavedSearch(search, on: playlist)
        onPick()
    }
}
