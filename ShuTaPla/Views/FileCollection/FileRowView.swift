//
//  FileRowView.swift
//  ShuTaPla
//
//  One row in the Manager file list: the filename and a right-aligned metadata cluster
//  (pixel dimensions, on-disk size, running time — each shown for the types that carry it),
//  with a selection highlight and an inline rename field when this row is being renamed.
//

import SwiftUI

struct FileRowView: View {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    let isCurrent: Bool
    let isRenaming: Bool
    let isStripping: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(MediaMetadataService.self) private var metadataService
    @Environment(AppState.self) private var appState
    // The surface's pre-resolved folder URL, when it holds a scoped-access session open. Passed into
    // the metadata read so it appends the relative path instead of resolving the bookmark per file.
    @Environment(\.browsingFolderURL) private var browsingFolderURL

    var body: some View {
        Group {
            if isRenaming {
                RenameFileField(text: $draftName, onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                HStack(spacing: 12) {
                    fileName
                    Spacer(minLength: 8)
                    metadataColumns
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Fill the fixed row slot (`PagedList` frames the row to `fileListRowHeight`) so the
        // selection wash and the playback-cursor border span the whole row rather than just the
        // text, leaving no gap between a row's separator and the next row's shade.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : Color.clear)
        // A purple border marks the playback cursor, layered over the accent selection
        // wash so a current row that's also selected shows both cues.
        .overlay {
            if isCurrent { Rectangle().strokeBorder(Color.playbackCursor, lineWidth: 2) }
        }
        // Dim the row behind a spinner while its audio is being removed.
        .opacity(isStripping ? 0.5 : 1)
        .overlay(alignment: .trailing) {
            if isStripping {
                ProgressView().controlSize(.small).padding(.trailing, 10)
            }
        }
        .contentShape(Rectangle())
        // Metadata (duration, dimensions, size) is read once and cached on the model, so it
        // appears instantly on later displays and across launches. Images have no timeline but
        // do carry dimensions and size, so every type opens once — only when a field this type
        // needs is still missing, so a fully-cached row never re-opens and the columns (shown
        // synchronously from the model) don't flash empty on scroll-in.
        .task(id: metadataKey) {
            guard !file.hasCompleteMetadata(for: playlist.mediaType) else { return }
            _ = await metadataService.metadata(for: file, in: playlist, folderURL: browsingFolderURL)
        }
    }

    /// Re-extract when the file is replaced (id change), and when its bytes arrive from the cloud
    /// (`cloudStatus` flips to `.local`) so the row fills the metadata the evicted pass skipped.
    /// Keyed on local-ness, not the full status, so it re-fires only on that boundary.
    var metadataKey: String { "\(file.id)|\(file.cloudStatus == .local)" }

    private var fileName: some View {
        Text(file.fileName)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The right-aligned metadata cluster: dimensions and size for the visual types, plus
    /// running time for the timed ones. Each is a fixed-width column so values right-align and
    /// rows keep common right edges whatever each value's width. Audio carries no pixel
    /// dimensions; images no timeline — that column is dropped for the type that lacks it.
    private var metadataColumns: some View {
        HStack(spacing: 12) {
            if playlist.mediaType != .audio {
                column(file.pixelSize?.dimensionsText, width: 76)
            }
            sizeColumn
            if playlist.mediaType != .image {
                column(file.duration?.formattedDuration, width: 56)
            }
        }
    }

    /// The on-disk size, prefixed by the cloud-status glyph when the file isn't fully local. The
    /// glyph shares the size column's fixed width rather than occupying its own inline slot, so a
    /// non-local row keeps the exact column geometry of a local one — the badge adds no width and
    /// the size/duration columns stay aligned across the whole list.
    private var sizeColumn: some View {
        HStack(spacing: 4) {
            if file.cloudStatus.badgeSymbol != nil {
                Button { appState.downloadFiles([file]) } label: {
                    CloudStatusBadge(status: file.cloudStatus)
                }
                .buttonStyle(.plain)
                .help("Download from iCloud")
            }
            Text(file.fileSizeBytes?.formattedFileSize ?? "")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 64, alignment: .trailing)
    }

    /// One right-aligned, fixed-width metadata value — empty until its field is cached.
    private func column(_ text: String?, width: CGFloat) -> some View {
        Text(text ?? "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }
}
