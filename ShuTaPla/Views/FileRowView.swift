//
//  FileRowView.swift
//  ShuTaPla
//
//  One row in the Manager file list: filename and tag chips, with a selection
//  highlight, and an inline rename field when this row is being renamed.
//

import SwiftUI

struct FileRowView: View {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(DurationService.self) private var durations
    @State private var duration: TimeInterval?

    var body: some View {
        Group {
            if isRenaming {
                RenameFileField(text: $draftName, onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                HStack(spacing: 8) {
                    Text(file.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if !file.tags.isEmpty {
                        TagChips(tags: file.tags)
                    }
                    if playlist.mediaType == .video {
                        durationColumn
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        // Length is read once and cached on the model, so it appears instantly on
        // later displays and across launches. Images have no timeline.
        .task(id: file.id) {
            guard playlist.mediaType == .video else { return }
            duration = await durations.duration(for: file, in: playlist)
        }
    }

    /// A fixed-width trailing column so the value right-aligns and the tag chips of
    /// every row keep a common right edge whatever each duration's width.
    private var durationColumn: some View {
        Text(duration?.formattedDuration ?? "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .trailing)
    }
}

/// Compact, read-only tag chips. Editing lives in the tag panel (Task 7).
private struct TagChips: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
