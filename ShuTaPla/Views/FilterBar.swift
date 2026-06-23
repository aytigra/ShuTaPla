//
//  FilterBar.swift
//  ShuTaPla
//
//  The tag-filter controls shared by every surface that filters a playlist: an AND/OR
//  `TagTokenField` whose chips are the selected filter tags, the saved-search recents, and a
//  banner shown while a triage (service) filter overrides the tag filter. Every edit targets
//  the given `playlist`'s persisted `filterState` directly, so the same bar serves the Manager
//  and both player overlays — they differ only in which playlist they pass. The triage banner
//  reads from the model, so it appears (and clears) on any surface; the triage *toggles* live
//  in the Manager's center notices. Playlist-wide tag rename / remove lives in `PlaylistTagsView`.
//

import SwiftUI

struct FilterBar: View {
    let playlist: Playlist

    @Environment(AppState.self) private var appState

    private var serviceFilter: ServiceFilter? { playlist.filterState.serviceFilter }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Filter").font(.headline)
                Spacer()
                if !playlist.filterState.isEmpty, serviceFilter == nil {
                    Button("Clear") { appState.clearTagFilter(on: playlist) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if let service = serviceFilter {
                serviceBanner(service)
            } else {
                modePicker
                tagField
                Divider()
                savedSearches
            }
        }
        .padding(12)
    }

    // MARK: - Triage filter banner

    private func serviceBanner(_ service: ServiceFilter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: service.systemImage)
            Text("Showing \(service.label)").font(.callout)
            Spacer()
            Button("Show all") { appState.toggleServiceFilter(service, on: playlist) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Tag filter

    private var modePicker: some View {
        Picker("Match", selection: Binding(
            get: { playlist.filterState.filterMode },
            set: { appState.setFilterMode($0, on: playlist) }
        )) {
            Text("All tags").tag(FilterMode.and)
            Text("Any tag").tag(FilterMode.or)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(playlist.tagFrequency.isEmpty)
    }

    private var tagField: some View {
        TagTokenField(
            tokens: playlist.filterState.selectedTags,
            knownTags: playlist.tagFrequency,
            allowsCreate: false,
            placeholder: "Filter by tag",
            onAdd: { appState.toggleFilterTag($0, on: playlist) },
            onRemove: { appState.toggleFilterTag($0, on: playlist) }
        )
    }

    // MARK: - Saved searches

    private var savedSearches: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved Searches").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Save") { appState.saveCurrentSearch(on: playlist) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(playlist.filterState.isEmpty)
            }

            if playlist.savedSearches.isEmpty {
                Text("No saved searches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playlist.savedSearches) { search in
                    savedSearchRow(search)
                }
            }
        }
    }

    private func savedSearchRow(_ search: SavedSearch) -> some View {
        HStack(spacing: 6) {
            Button { appState.applySavedSearch(search, on: playlist) } label: {
                Text(search.tags.joined(separator: search.mode == .and ? "  +  " : "  /  "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { appState.removeSavedSearch(search, on: playlist) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove saved search")
        }
    }
}
