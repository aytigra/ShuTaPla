//
//  FilterBar.swift
//  ShuTaPla
//
//  The tag-filter controls shared by every surface that filters a playlist: an AND/OR
//  `TagTokenField` whose chips are the selected filter tags, the saved-search recents,
//  and — on channels that have them — a banner shown while a service filter overrides
//  the tag filter. The `scope` picks the routing: `.manager` filters the Manager's active
//  scope (visual or audio, with the service-filter banner) and is reused by the visual
//  player overlay; `.audio` filters the audio channel independently (search-only, no
//  service filters). Playlist-wide tag rename / remove lives in `PlaylistTagsView`.
//

import SwiftUI

/// Which channel a `FilterBar` routes through. The single discriminator behind every
/// difference between the two bars — `LibrarySurface` derives it from the channel's media
/// type, and `TagSidebar` passes `.manager` for the Manager panel.
enum FilterScope {
    case manager
    case audio
}

struct FilterBar: View {
    let scope: FilterScope
    let playlist: Playlist

    @Environment(AppState.self) private var appState

    private var routing: FilterRouting {
        switch scope {
        case .manager: return .manager(appState)
        case .audio: return .audio(appState)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Filter").font(.headline)
                Spacer()
                if !playlist.filterState.isEmpty, routing.serviceFilter == nil {
                    Button("Clear") { routing.onClear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if let service = routing.serviceFilter {
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

    // MARK: - Service filter banner

    private func serviceBanner(_ service: ServiceFilter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: service.systemImage)
            Text("Showing \(service.label)").font(.callout)
            Spacer()
            Button("Show all") { routing.onClearServiceFilter() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Tag filter

    private var modePicker: some View {
        Picker("Match", selection: routing.filterMode) {
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
            onAdd: { routing.onToggleTag($0) },
            onRemove: { routing.onToggleTag($0) }
        )
    }

    // MARK: - Saved searches

    private var savedSearches: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved Searches").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Save") { routing.onSave() }
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
            Button { routing.onApply(search) } label: {
                Text(search.tags.joined(separator: search.mode == .and ? "  +  " : "  /  "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { routing.onRemove(search) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove saved search")
        }
    }
}

/// The scope-specific actions a `FilterBar` triggers, resolved from `AppState` once per
/// render. Audio leaves `serviceFilter` nil, so the banner never shows on that channel.
private struct FilterRouting {
    let filterMode: Binding<FilterMode>
    let onToggleTag: (String) -> Void
    let onClear: () -> Void
    let onSave: () -> Void
    let onApply: (SavedSearch) -> Void
    let onRemove: (SavedSearch) -> Void
    let serviceFilter: ServiceFilter?
    let onClearServiceFilter: () -> Void
}

private extension FilterRouting {
    /// Routes through the Manager's active-scope filter API — so the one control filters the
    /// visual or audio playlist depending on scope — and surfaces the service-filter banner
    /// from the center-panel counter notices.
    @MainActor
    static func manager(_ appState: AppState) -> FilterRouting {
        FilterRouting(
            filterMode: Binding(
                get: { appState.managerFilterMode },
                set: { appState.managerFilterMode = $0 }
            ),
            onToggleTag: { appState.managerToggleFilterTag($0) },
            onClear: { appState.managerClearFilter() },
            onSave: { appState.managerSaveSearch() },
            onApply: { appState.managerApplySearch($0) },
            onRemove: { appState.managerRemoveSearch($0) },
            serviceFilter: appState.activeServiceFilter,
            onClearServiceFilter: {
                if let service = appState.activeServiceFilter { appState.toggleServiceFilter(service) }
            }
        )
    }

    /// Routes through the audio filter API so it edits the audio channel independently of the
    /// Manager's selected video/image playlist. Search-only — audio has no service filters.
    @MainActor
    static func audio(_ appState: AppState) -> FilterRouting {
        FilterRouting(
            filterMode: Binding(
                get: { appState.audioFilterMode },
                set: { appState.audioFilterMode = $0 }
            ),
            onToggleTag: { appState.toggleAudioFilterTag($0) },
            onClear: { appState.clearAudioFilter() },
            onSave: { appState.saveAudioSearch() },
            onApply: { appState.applyAudioSearch($0) },
            onRemove: { appState.removeAudioSearch($0) },
            serviceFilter: nil,
            onClearServiceFilter: {}
        )
    }
}
