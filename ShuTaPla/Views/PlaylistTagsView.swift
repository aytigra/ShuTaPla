//
//  PlaylistTagsView.swift
//  ShuTaPla
//
//  The Manager right panel's tag-management mode: a flat list of every tag in the
//  playlist with its file count, each row offering an inline replace (the field takes
//  focus immediately, commits with [return], cancels with [esc]) and a remove action.
//  Removal renames files on disk and can't be undone, so it asks for confirmation.
//  Lets tags be curated playlist-wide without selecting or opening any file.
//

import SwiftUI

struct PlaylistTagsView: View {
    let playlist: Playlist
    @Environment(AppState.self) private var appState

    @State private var replacingTag: String?
    @State private var replaceDraft = ""
    @FocusState private var replaceFieldFocused: Bool

    /// Tags sorted alphabetically (case-insensitive) so a given tag is easy to find.
    private var tags: [(name: String, count: Int)] {
        playlist.tagFrequency
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Manage Tags")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if tags.isEmpty {
            Text("This playlist has no tags yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tags, id: \.name) { tag in
                        row(tag.name, count: tag.count)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ tag: String, count: Int) -> some View {
        if replacingTag == tag {
            HStack(spacing: 6) {
                TextField("Tag", text: $replaceDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($replaceFieldFocused)
                    .onAppear { replaceFieldFocused = true }
                    .onSubmit { commitReplace(tag) }
                    .onExitCommand { replacingTag = nil }
                Button("Replace") { commitReplace(tag) }
                Button("Cancel") { replacingTag = nil }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) {
                Text(tag)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { beginReplace(tag) } label: {
                    Label("Replace Tag", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Replace this tag in every file")

                Button(role: .destructive) { appState.requestTagRemoval(tag) } label: {
                    Label("Remove Tag", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Remove this tag from every file")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { appState.setTagFilter(to: tag, on: playlist) }
            .help("Filter the playlist by this tag")
        }
    }

    // MARK: - Actions

    private func beginReplace(_ tag: String) {
        replaceDraft = tag
        replacingTag = tag
    }

    private func commitReplace(_ oldTag: String) {
        replacingTag = nil
        appState.commitTagReplace(oldTag, with: replaceDraft, on: playlist)
    }
}
