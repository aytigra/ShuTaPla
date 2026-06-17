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
    let isStripping: Bool
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
                // One line while it fits; once the name, chips, and length can't share
                // a row, the chips wrap onto their own line beneath the name.
                ViewThatFits(in: .horizontal) {
                    singleLine
                    stacked
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        // Dim the row behind a spinner while its audio is being removed.
        .opacity(isStripping ? 0.5 : 1)
        .overlay(alignment: .trailing) {
            if isStripping {
                ProgressView().controlSize(.small).padding(.trailing, 10)
            }
        }
        .contentShape(Rectangle())
        // Length is read once and cached on the model, so it appears instantly on
        // later displays and across launches. Images have no timeline.
        .task(id: file.id) {
            guard playlist.mediaType == .video else { return }
            duration = await durations.duration(for: file, in: playlist)
        }
    }

    /// Name, chips, and length all on one row.
    private var singleLine: some View {
        HStack(spacing: 8) {
            fileName
            Spacer(minLength: 8)
            if !file.tags.isEmpty {
                TagChips(tags: file.tags)
            }
            if playlist.mediaType == .video {
                durationColumn
            }
        }
    }

    /// Name (and length) on top, chips wrapped onto a flow beneath — the fallback
    /// when the row is too narrow for everything to sit on one line.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                fileName
                Spacer(minLength: 8)
                if playlist.mediaType == .video {
                    durationColumn
                }
            }
            if !file.tags.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(file.tags, id: \.self) { TagChip(tag: $0) }
                }
            }
        }
    }

    private var fileName: some View {
        Text(file.fileName)
            .lineLimit(1)
            .truncationMode(.middle)
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
            ForEach(tags, id: \.self) { TagChip(tag: $0) }
        }
    }
}

/// One read-only tag pill.
private struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
