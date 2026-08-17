//
//  FilterStrip.swift
//  ShuTaPla
//
//  The single home for everything that narrows a playlist: the tag filter, the saved searches over
//  it, and the triage counts. It sits at the top of the file list in Manager and in both player
//  overlays, and shows exactly one of the four `FilterStripMode` cases — the tag filter and a triage
//  filter can both be set, and this is where that is resolved by precedence rather than in the model.
//
//  Collapsed it is one row: `› Filter`, `Searches`, and whatever the mode allows beside them. The
//  two buttons carry the state, so the strip answers "filtered, by what" without being expanded —
//  an ad-hoc filter tints `Filter`, and an applied saved search puts its name on `Searches`.
//  Expansion is view state, not persisted and not per playlist, so each mount keeps its own.
//

import SwiftUI
import SwiftData

struct FilterStrip: View {
    let playlist: Playlist

    /// Whether the strip carries the triage surfaces — the counts and the review banners. Manager
    /// does; the player overlays don't, since both are entered from the Manager and neither is
    /// playable. A triage filter set there still shows here, with its way out, so the player is
    /// never stuck inside one.
    var showsTriage: Bool = true

    @Environment(AppState.self) private var appState

    @State private var expanded = false
    @State private var searchesOpen = false
    /// The collapsed row's height — where the `Searches` dropdown hangs from.
    @State private var rowHeight: CGFloat = 0

    private var mode: FilterStripMode {
        FilterStripMode.resolve(
            inReviewMode: showsTriage && appState.inReviewMode,
            serviceFilter: playlist.serviceFilter,
            hasTagFilter: playlist.currentFilter != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { rowHeight = $0 }

            // Expansion survives a detour through triage as view state, but the panel edits a filter
            // the strip is not showing then, so it is mounted only while the controls are.
            if expanded, mode.showsFilterControls {
                Divider()
                expandedPanel
            }
        }
        .overlay(alignment: .topLeading) {
            if searchesOpen, mode.showsFilterControls {
                SavedSearchesDropdown(
                    playlist: playlist,
                    anchorHeight: rowHeight,
                    onPick: { searchesOpen = false }
                )
                .offset(y: rowHeight)
            }
        }
    }

    // MARK: - Collapsed row

    @ViewBuilder
    private var collapsedRow: some View {
        HStack(spacing: 8) {
            switch mode {
            case .reviewing:
                reviewBanner
            case .serviceFiltered(let filter):
                banner("Showing \(filter.label)", systemImage: filter.systemImage, action: "Show All") {
                    appState.toggleServiceFilter(filter, on: playlist)
                }
            case .tagFiltered, .unfiltered:
                filterButton
                searchesButton
                if mode.showsClear {
                    Button("Clear") { appState.clearTagFilter(on: playlist) }
                        .buttonStyle(.borderless)
                }
                if showsTriage, mode.showsTriageCounts { triageCounts }
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// Whichever review surface is up, with the way out of it. Both are Manager-only, and a filter
    /// edit or a playlist switch also leaves them.
    @ViewBuilder
    private var reviewBanner: some View {
        if appState.duplicateSearchActive {
            banner("Showing duplicates", systemImage: "square.on.square", action: "Done") {
                appState.setDuplicateSearch(false)
            }
        } else {
            banner("Showing skipped", systemImage: "nosign", action: "Done") {
                appState.setSkippedReview(false)
            }
        }
    }

    /// The shape every mode that owns the whole row shares: what is being shown, and the one control
    /// that leaves it. Its presence is what makes the hidden tag filter underneath recoverable.
    private func banner(
        _ text: String, systemImage: String, action: String, perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var filterButton: some View {
        Button {
            expanded.toggle()
            if expanded { searchesOpen = false }
        } label: {
            // A plain button hit-tests the glyphs it draws, so without this the gap between the
            // caret and the word falls through and the control feels broken.
            Label("Filter", systemImage: expanded ? "chevron.down" : "chevron.right")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tinted for an ad-hoc filter only: a saved one is named on `Searches` instead, so the two
        // controls never claim the same filter twice.
        .foregroundStyle(tint(playlist.currentFilter != nil && playlist.activeSavedSearch == nil))
        .help(expanded ? "Hide the tag filter" : "Show the tag filter")
    }

    /// A control that carries state is tinted; one that doesn't reads as a plain control.
    private func tint(_ isSet: Bool) -> Color { isSet ? .accentColor : .primary }

    private var searchesButton: some View {
        Button { searchesOpen.toggle() } label: {
            Label(playlist.activeSavedSearch?.name ?? "Searches", systemImage: "bookmark")
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint(playlist.activeSavedSearch != nil))
        .help("Pick or reorder a saved search")
    }

    /// Untagged / invalid-tagging each set the matching triage filter, which then owns the row; the
    /// skipped count enters the skipped-review mode instead — skipped files are wrong-type or
    /// unplayable, reviewed as a list rather than filtered into playback.
    @ViewBuilder
    private var triageCounts: some View {
        let _ = appState.sequences.version   // re-derive the counts when the sequence changes
        let (untagged, invalid, skipped) = playlist.serviceFilterCounts

        if untagged > 0 { triageCount("\(untagged) untagged", sets: .untagged) }
        if invalid > 0 { triageCount("\(invalid) invalid tagging", sets: .invalidTagging) }
        if skipped > 0 {
            count("\(skipped) skipped", systemImage: "nosign", help: "Review skipped files") {
                appState.reviewSkipped(in: playlist)
            }
        }
    }

    /// A count that sets its triage filter, which then owns the row — so it never shows as active
    /// here, and the way back out is the banner that replaces it.
    private func triageCount(_ text: String, sets filter: ServiceFilter) -> some View {
        count(text, systemImage: filter.systemImage, help: "Show only these") {
            appState.toggleServiceFilter(filter, on: playlist)
        }
    }

    private func count(
        _ text: String, systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Expanded panel

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Raised so a field's suggestion dropdown draws over the name row rather than under it.
            FilterFieldGrid(playlist: playlist)
                .zIndex(1)
            // Keyed to the playlist, which the rest of the strip is not: the row holds a typed draft
            // and an uncommitted rename, and both belong to the playlist they were entered over.
            SavedSearchNameRow(playlist: playlist)
                .id(playlist.persistentModelID)
        }
        .padding(12)
    }
}
