//
//  FilterBar.swift
//  ShuTaPla
//
//  The filter controls in the Manager tag panel: an AND/OR tag cloud over the
//  playlist's tags, the saved-search recents, and a banner shown while a service
//  filter (from the center-panel counter notices) overrides the tag filter.
//  Each tag chip also hosts the playlist-wide rename / remove operations.
//

import SwiftUI

struct FilterBar: View {
    let playlist: Playlist
    @Environment(AppState.self) private var appState

    @State private var renamingTag: String?
    @State private var renameDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Filter").font(.headline)
                Spacer()
                if !playlist.filterState.isEmpty, appState.activeServiceFilter == nil {
                    Button("Clear") { appState.clearTagFilter() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if let service = appState.activeServiceFilter {
                serviceBanner(service)
            } else {
                modePicker
                tagCloud
                Divider()
                savedSearches
            }
        }
        .padding(12)
        .alert(
            "Tag change failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Service filter banner

    private func serviceBanner(_ service: ServiceFilter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: service))
            Text("Showing \(name(for: service))").font(.callout)
            Spacer()
            Button("Show all") { appState.toggleServiceFilter(service) }
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
            set: { appState.setFilterMode($0) }
        )) {
            Text("All tags").tag(FilterMode.and)
            Text("Any tag").tag(FilterMode.or)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(playlist.tagFrequency.isEmpty)
    }

    @ViewBuilder
    private var tagCloud: some View {
        if playlist.tagFrequency.isEmpty {
            Text("No tags in this playlist yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            FlowLayout {
                ForEach(sortedTags, id: \.self) { tag in
                    filterChip(tag)
                }
            }
        }
    }

    @ViewBuilder
    private func filterChip(_ tag: String) -> some View {
        if renamingTag == tag {
            TextField("Tag", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit { commitTagRename(tag) }
                .onExitCommand { renamingTag = nil }
        } else {
            let selected = playlist.filterState.selectedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            Button { appState.toggleFilterTag(tag) } label: {
                HStack(spacing: 4) {
                    Text(tag)
                    Text("\(playlist.tagFrequency[tag] ?? 0)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename Tag…") {
                    renameDraft = tag
                    renamingTag = tag
                }
                Button("Remove From All Files", role: .destructive) {
                    Task {
                        if let error = await appState.removeTagAcrossPlaylist(playlist, tag: tag) {
                            errorMessage = error
                        }
                    }
                }
            }
        }
    }

    private func commitTagRename(_ oldTag: String) {
        let new = renameDraft.trimmingCharacters(in: .whitespaces)
        renamingTag = nil
        guard TagParser.isValidTag(new), new.caseInsensitiveCompare(oldTag) != .orderedSame else { return }
        Task {
            if let error = await appState.renameTagAcrossPlaylist(playlist, from: oldTag, to: new) {
                errorMessage = error
            }
        }
    }

    private var sortedTags: [String] {
        playlist.tagFrequency.keys.sorted { a, b in
            let fa = playlist.tagFrequency[a] ?? 0
            let fb = playlist.tagFrequency[b] ?? 0
            if fa != fb { return fa > fb }
            return a.lowercased() < b.lowercased()
        }
    }

    // MARK: - Saved searches

    private var savedSearches: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved Searches").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Save") { appState.saveCurrentSearch() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(playlist.filterState.isEmpty)
            }

            if playlist.savedSearches.isEmpty {
                Text("No saved searches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(playlist.savedSearches.enumerated()), id: \.offset) { _, search in
                    savedSearchRow(search)
                }
            }
        }
    }

    private func savedSearchRow(_ search: SavedSearch) -> some View {
        HStack(spacing: 6) {
            Button { appState.applySavedSearch(search) } label: {
                Text(search.tags.joined(separator: search.mode == .and ? "  +  " : "  /  "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { appState.removeSavedSearch(search) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove saved search")
        }
    }

    // MARK: - Service filter labels

    private func icon(for service: ServiceFilter) -> String {
        switch service {
        case .untagged: return "tag.slash"
        case .invalidTagging: return "exclamationmark.triangle"
        case .skipped: return "nosign"
        }
    }

    private func name(for service: ServiceFilter) -> String {
        switch service {
        case .untagged: return "untagged files"
        case .invalidTagging: return "files with invalid tagging"
        case .skipped: return "skipped files"
        }
    }
}
