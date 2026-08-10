//
//  SavedSearchNameRow.swift
//  ShuTaPla
//
//  Names the filter, and doubles as the saved/ad-hoc indicator: an empty field over `Save` while the
//  filter is ad-hoc, the search's name over `Delete saved search` once it has one. There is no update
//  button — the lists write through to the search as they are edited, so a rename is the only thing
//  left to commit.
//
//  A view of its own because the draft it holds belongs to one playlist. The strip mounts it under
//  `.id(playlist.persistentModelID)`, so a scope switch ends this identity and starts another: the
//  draft, and the rename it is waiting to commit, go with the playlist they were typed over instead
//  of landing on the next one.
//

import SwiftUI
import SwiftData

struct SavedSearchNameRow: View {
    let playlist: Playlist

    @Environment(AppState.self) private var appState

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name this search", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .focused($focused)
                .onSubmit { commitName() }
                // Clicking scenery — the file list, the strip around the field — leaves an AppKit
                // field editor focused, so the caret sits in a field the user has visibly left and
                // the rename below never fires. Mounted only while focused, so the click that
                // focuses the field can't be the one that resigns it.
                .background { if focused { ClickOutsideMonitor { focused = false } } }
                // A rename lands on leaving the field as well as on [return], so a typed name isn't
                // lost by clicking away; `renameSavedSearch` is what substitutes a blank one.
                .onChange(of: focused) { _, hasFocus in if !hasFocus { commitRename() } }

            if let search = playlist.activeSavedSearch {
                // The role is what the strip's alert reads; macOS renders it only in menus and
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
        // Mounted with the expanded panel, so this seeds the draft from whatever is applied then.
        .onAppear { draft = storedName }
        // Applying another search (or clearing the filter) re-seeds the field from what is applied
        // now. Saving re-seeds it too — the search's stored name is the trimmed one.
        .onChange(of: playlist.activeSavedSearch?.persistentModelID) { _, _ in draft = storedName }
        // Collapsing the strip takes the field with it — and a click on `Filter` need not resign an
        // AppKit field editor first — so a typed rename commits here rather than being dropped.
        .onDisappear { commitRename() }
    }

    /// What the field shows when it is not being typed in: the applied search's name, or nothing.
    private var storedName: String { playlist.activeSavedSearch?.name ?? "" }

    /// The explicit commits — `Save` and `[return]`: a rename of the applied search, or the save
    /// that creates one. A save refused as a duplicate reports itself through `errorNotice`.
    private func commitName() {
        guard playlist.activeSavedSearch == nil else { return commitRename() }
        appState.saveCurrentSearch(named: draft, on: playlist)
    }

    /// The implicit commits — leaving the field, collapsing the strip. Only ever a rename: creating
    /// a search is `Save`'s alone, so a name typed over an ad-hoc filter and abandoned stays a draft.
    private func commitRename() {
        guard let search = playlist.activeSavedSearch, draft != search.name else { return }
        appState.renameSavedSearch(search, to: draft)
        // What was stored is the trimmed name, or the placeholder if it was blank — not what was
        // typed. Showing it back is both what the field owes the user and what keeps the guard above
        // honest: left diverged, it would read as changed forever and re-save on every focus cycle.
        draft = storedName
    }
}
