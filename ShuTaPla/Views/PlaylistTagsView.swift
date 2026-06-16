//
//  PlaylistTagsView.swift
//  ShuTaPla
//
//  The Manager right panel's tag-management mode: a flat list of every tag in the
//  playlist with its file count, each row offering an inline rename (the field takes
//  focus immediately, commits with [return], cancels with [esc]) and a remove action.
//  Removal renames files on disk and can't be undone, so it asks for confirmation.
//  Lets tags be curated playlist-wide without selecting or opening any file.
//

import SwiftUI

struct PlaylistTagsView: View {
    let playlist: Playlist
    @Environment(AppState.self) private var appState

    @State private var renamingTag: String?
    @State private var renameDraft = ""
    @State private var errorMessage: String?
    @FocusState private var renameFieldFocused: Bool

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
        .alert(
            appState.pendingTagRemoval.map { "Remove “\($0)” from every file in this playlist?" } ?? "",
            isPresented: Binding(get: { appState.pendingTagRemoval != nil }, set: { if !$0 { appState.cancelTagRemoval() } })
        ) {
            Button("Remove Tag", role: .destructive) { appState.confirmTagRemoval() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { appState.cancelTagRemoval() }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("This renames the files on disk and can't be undone.")
        }
        .alert(
            "Tag change failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Couldn't remove tag",
            isPresented: Binding(get: { appState.tagRemovalError != nil }, set: { if !$0 { appState.tagRemovalError = nil } })
        ) {
            Button("OK", role: .cancel) { appState.tagRemovalError = nil }
        } message: {
            Text(appState.tagRemovalError ?? "")
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
        if renamingTag == tag {
            HStack(spacing: 6) {
                TextField("Tag", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onAppear { renameFieldFocused = true }
                    .onSubmit { commitRename(tag) }
                    .onExitCommand { renamingTag = nil }
                Button("Rename") { commitRename(tag) }
                Button("Cancel") { renamingTag = nil }
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
                Button { beginRename(tag) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this tag across the playlist")

                Button(role: .destructive) { appState.pendingTagRemoval = tag } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this tag from every file")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Actions

    private func beginRename(_ tag: String) {
        renameDraft = tag
        renamingTag = tag
    }

    private func commitRename(_ oldTag: String) {
        let new = renameDraft.trimmingCharacters(in: .whitespaces)
        renamingTag = nil
        // An empty entry or an unchanged name just closes the editor; a non-empty but
        // malformed entry is reported rather than silently dropped.
        guard !new.isEmpty, new.caseInsensitiveCompare(oldTag) != .orderedSame else { return }
        guard TagParser.isValidTag(new) else {
            errorMessage = "“\(new)” isn’t a valid tag (letters, digits, or underscore; at least \(TagParser.minTagLength) characters)."
            return
        }
        Task {
            if let error = await appState.renameTagAcrossPlaylist(playlist, from: oldTag, to: new) {
                errorMessage = error
            }
        }
    }
}
