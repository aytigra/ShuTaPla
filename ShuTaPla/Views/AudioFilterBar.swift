//
//  AudioFilterBar.swift
//  ShuTaPla
//
//  The filter controls for the extended audio overlay: an AND/OR `TagTokenField` over
//  the active audio playlist's tags plus its saved-search recents. The same shape as
//  the Manager `FilterBar`, but search-only (no tag creation) and routed through the
//  audio-scoped filter API so it edits the audio channel independently of the Manager's
//  selected video/image playlist. Audio has no service filters.
//

import SwiftUI

struct AudioFilterBar: View {
    @Environment(AppState.self) private var appState

    private var playlist: Playlist? { appState.activeAudioPlaylist }

    var body: some View {
        if let playlist {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Filter").font(.headline)
                    Spacer()
                    if !playlist.filterState.isEmpty {
                        Button("Clear") { appState.clearAudioFilter() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }

                Picker("Match", selection: Binding(
                    get: { appState.audioFilterMode },
                    set: { appState.audioFilterMode = $0 }
                )) {
                    Text("All tags").tag(FilterMode.and)
                    Text("Any tag").tag(FilterMode.or)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(playlist.tagFrequency.isEmpty)

                TagTokenField(
                    tokens: playlist.filterState.selectedTags,
                    knownTags: playlist.tagFrequency,
                    allowsCreate: false,
                    placeholder: "Filter by tag",
                    onAdd: { appState.toggleAudioFilterTag($0) },
                    onRemove: { appState.toggleAudioFilterTag($0) }
                )

                Divider()
                savedSearches(playlist)
            }
            .padding(12)
        }
    }

    private func savedSearches(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Saved Searches").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Save") { appState.saveAudioSearch() }
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
                    HStack(spacing: 6) {
                        Button { appState.applyAudioSearch(search) } label: {
                            Text(search.tags.joined(separator: search.mode == .and ? "  +  " : "  /  "))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button { appState.removeAudioSearch(search) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove saved search")
                    }
                }
            }
        }
    }
}
