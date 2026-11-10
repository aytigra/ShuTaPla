//
//  TagEditorView.swift
//  ShuTaPla
//
//  Tag editor for the current file-list selection. For one or more validly-tagged
//  files it shows the tags in common in a `TagTokenField` whose dropdown can create
//  new tags. A lone file with invalid tagging gets a plain rename field with an
//  explanatory message until its name parses cleanly; in a multi-selection, invalid
//  files are excluded.
//

import SwiftUI

struct TagEditorView: View {
    let playlist: Playlist
    let files: [PlaylistFile]
    /// Focuses the tag input as soon as the editor appears. The Visual Overlay
    /// turns this on; the Manager tag panel leaves it off.
    var autoFocus: Bool = false
    @Environment(AppState.self) private var appState

    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
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

            TagTokenField(
                tokens: commonTags,
                knownTags: playlist.tagFrequency,
                allowsCreate: true,
                placeholder: "Add a tag",
                autoFocus: autoFocus,
                onAdd: { add($0) },
                onRemove: { remove($0) }
            )
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
        appState.commitRename(of: file.id, to: renameDraft)
    }

    // MARK: - Actions

    private func add(_ tag: String) {
        appState.runFileOp(editableFiles.map(\.id), failure: ErrorNotice.Title.tagChange) { await appState.addTag(tag, to: $0) }
    }

    private func remove(_ tag: String) {
        appState.runFileOp(editableFiles.map(\.id), failure: ErrorNotice.Title.tagChange) { await appState.removeTag(tag, from: $0) }
    }

    // MARK: - Derived

    /// Reflects how many files the editor targets: one file's own tags, or the
    /// tags shared across a multi-selection.
    private var title: String {
        switch files.count {
        case 0: return "Tags"
        case 1: return "File Tags"
        default: return "Common Tags"
        }
    }

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
        var common = first.tagNames
        for file in editableFiles.dropFirst() {
            let lower = Set(file.tagNames.map { $0.lowercased() })
            common = common.filter { lower.contains($0.lowercased()) }
        }
        return common
    }
}
