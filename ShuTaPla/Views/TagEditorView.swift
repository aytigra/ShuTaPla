//
//  TagEditorView.swift
//  ShuTaPla
//
//  Tag editor for the current file-list selection. For one or more validly-tagged
//  files it shows the tags in common as removable chips plus an autocomplete input
//  (enter to add, arrows to move through suggestions, esc to clear). A lone file
//  with invalid tagging gets a plain rename field with an explanatory message until
//  its name parses cleanly; in a multi-selection, invalid files are excluded.
//

import SwiftUI

struct TagEditorView: View {
    let playlist: Playlist
    let files: [PlaylistFile]
    @Environment(AppState.self) private var appState

    @State private var input = ""
    @State private var highlighted = 0
    @State private var renameDraft = ""
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.headline)
            content
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

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            hint("Select files to edit their tags.")
        } else if let invalid = soleInvalidFile {
            invalidEditor(invalid)
        } else if editableFiles.isEmpty {
            hint("All selected files have invalid tagging. Fix their names to edit tags.")
        } else {
            editor
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if excludedInvalidCount > 0 {
                Label("\(excludedInvalidCount) invalid-tagging file(s) excluded", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            commonTagChips
            tagInput
            suggestionList
        }
    }

    @ViewBuilder
    private var commonTagChips: some View {
        if commonTags.isEmpty {
            Text(files.count > 1 ? "No tags in common." : "No tags yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            FlowLayout {
                ForEach(commonTags, id: \.self) { tag in
                    removableChip(tag)
                }
            }
        }
    }

    private func removableChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
            Button { remove(tag) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
    }

    private var tagInput: some View {
        TextField("Add a tag", text: $input)
            .textFieldStyle(.roundedBorder)
            .focused($inputFocused)
            .onSubmit(commit)
            .onExitCommand { input = ""; highlighted = 0 }
            .onChange(of: input) { highlighted = 0 }
            .onMoveCommand { direction in
                switch direction {
                case .down where !suggestions.isEmpty:
                    highlighted = min(highlighted + 1, suggestions.count - 1)
                case .up:
                    highlighted = max(highlighted - 1, 0)
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, tag in
                    Button { add(tag) } label: {
                        HStack {
                            Text(tag)
                            Spacer()
                            Text("\(playlist.tagFrequency[tag] ?? 0)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Invalid tagging

    private func invalidEditor(_ file: PlaylistFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Invalid tag syntax", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("This name has more than one bracket group or nested brackets. Rename it to a single bracket group to edit tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filename", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitInvalidRename(file) }
            Button("Rename") { commitInvalidRename(file) }
        }
        .id(file.id)               // refresh the draft when the invalid file changes
        .onAppear { renameDraft = file.fileName }
    }

    private func commitInvalidRename(_ file: PlaylistFile) {
        let name = renameDraft
        Task {
            if let error = await appState.renameFile(file, to: name) { errorMessage = error }
        }
    }

    // MARK: - Actions

    private func commit() {
        if !suggestions.isEmpty, highlighted < suggestions.count {
            add(suggestions[highlighted])
        } else {
            let tag = input.trimmingCharacters(in: .whitespaces)
            guard TagParser.isValidTag(tag) else { return }
            add(tag)
        }
    }

    private func add(_ tag: String) {
        input = ""
        highlighted = 0
        Task {
            if let error = await appState.addTag(tag, to: editableFiles) { errorMessage = error }
        }
    }

    private func remove(_ tag: String) {
        Task {
            if let error = await appState.removeTag(tag, from: editableFiles) { errorMessage = error }
        }
    }

    // MARK: - Derived

    private var editableFiles: [PlaylistFile] {
        files.filter { $0.taggingStatus != .invalid }
    }

    private var excludedInvalidCount: Int {
        files.count - editableFiles.count
    }

    /// A single selected file that is invalid-tagged — the only case that swaps in
    /// the rename field. Multi-selections route through the chip editor instead.
    private var soleInvalidFile: PlaylistFile? {
        guard files.count == 1, let file = files.first, file.taggingStatus == .invalid else { return nil }
        return file
    }

    /// Tags present on every editable file (case-insensitive), keeping the casing
    /// from the first file.
    private var commonTags: [String] {
        guard let first = editableFiles.first else { return [] }
        var common = first.tags
        for file in editableFiles.dropFirst() {
            let lower = Set(file.tags.map { $0.lowercased() })
            common = common.filter { lower.contains($0.lowercased()) }
        }
        return common
    }

    /// Playlist tags not already in common, ranked by frequency then name, matched
    /// against the current input.
    private var suggestions: [String] {
        let already = Set(commonTags.map { $0.lowercased() })
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        return playlist.tagFrequency.keys
            .filter { !already.contains($0.lowercased()) }
            .filter { query.isEmpty || $0.lowercased().contains(query) }
            .sorted { a, b in
                let fa = playlist.tagFrequency[a] ?? 0
                let fb = playlist.tagFrequency[b] ?? 0
                if fa != fb { return fa > fb }
                return a.lowercased() < b.lowercased()
            }
            .prefix(8)
            .map { $0 }
    }
}
