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
    @State private var nameDraft = ""
    /// The collapsed row's height — where the `Searches` dropdown hangs from.
    @State private var rowHeight: CGFloat = 0
    @FocusState private var nameFocused: Bool

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
        // Hosted here, beside the two controls that raise it — only one strip is ever mounted, since
        // the Manager carries no overlay and the two overlays that carry one are mutually exclusive.
        .alert(
            appState.pendingConfirmation?.savedSearchToDelete
                .map { "Delete the saved search “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { appState.pendingConfirmation?.savedSearchToDelete != nil },
                set: { if !$0 { appState.cancelConfirmation() } }
            )
        ) {
            Button("Delete", role: .destructive) { appState.confirmConfirmation() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelConfirmation() }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("Its tag lists go with it, leaving the playlist unfiltered if it is the one applied.")
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
            nameRow
        }
        .padding(12)
        // The panel is mounted on expand, so this seeds the draft from whatever is applied then;
        // `nameRow` keeps it in step from there.
        .onAppear { nameDraft = playlist.activeSavedSearch?.name ?? "" }
        // Collapsing the strip takes the field with it — and a click on `Filter` need not resign an
        // AppKit field editor first — so a typed rename commits here rather than being dropped.
        .onDisappear { commitRename() }
    }

    /// Names the filter, and doubles as the saved/ad-hoc indicator: an empty field over `Save` while
    /// the filter is ad-hoc, the search's name over `Delete saved search` once it has one. There is
    /// no update button — the lists write through to the search as they are edited, so a rename is
    /// the only thing left to commit.
    private var nameRow: some View {
        HStack(spacing: 8) {
            TextField("Name this search", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .focused($nameFocused)
                .onSubmit { commitName() }
                // Clicking scenery — the file list, the strip around the field — leaves an AppKit
                // field editor focused, so the caret sits in a field the user has visibly left and
                // the rename below never fires. Mounted only while focused, so the click that
                // focuses the field can't be the one that resigns it.
                .background { if nameFocused { ClickOutsideMonitor { nameFocused = false } } }
                // A rename lands on leaving the field as well as on [return], so a typed name isn't
                // lost by clicking away; `renameSavedSearch` is what substitutes a blank one.
                .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }

            if let search = playlist.activeSavedSearch {
                // The role is what the alert below reads; macOS renders it only in menus and
                // alerts, so a button sitting in a row states it itself.
                Button("Delete saved search", role: .destructive) {
                    appState.requestSavedSearchDelete(search)
                }
                .foregroundStyle(.red)
            } else {
                Button("Save") { commitName() }
                    .disabled(playlist.currentFilter == nil)
            }
            Spacer(minLength: 0)
        }
        // Applying another search (or clearing the filter) re-seeds the field from what is applied
        // now. Saving re-seeds it too — the search's stored name is the trimmed one.
        .onChange(of: playlist.activeSavedSearch?.persistentModelID) { _, _ in
            nameDraft = playlist.activeSavedSearch?.name ?? ""
        }
    }

    /// The explicit commits — `Save` and `[return]`: a rename of the applied search, or the save
    /// that creates one. A save refused as a duplicate reports itself through `errorNotice`.
    private func commitName() {
        guard playlist.activeSavedSearch == nil else { return commitRename() }
        appState.saveCurrentSearch(named: nameDraft, on: playlist)
    }

    /// The implicit commits — leaving the field, collapsing the strip. Only ever a rename: creating
    /// a search is `Save`'s alone, so a name typed over an ad-hoc filter and abandoned stays a draft.
    private func commitRename() {
        guard let search = playlist.activeSavedSearch, nameDraft != search.name else { return }
        appState.renameSavedSearch(search, to: nameDraft)
    }
}
