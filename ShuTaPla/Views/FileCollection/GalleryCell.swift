//
//  GalleryCell.swift
//  ShuTaPla
//
//  One gallery tile in the Manager center: an async-loaded thumbnail with the filename
//  (or an inline rename field) beneath it, plus a selection highlight and metadata badges.
//  The gallery presentation of `FileCollectionView`; the list presentation's row is
//  `FileRowView`.
//
//  The thumbnail itself is `GalleryThumbnailImage`, which owns the loaded image and its generation.
//  Everything here reads only what holds still during a scroll — the name, the cached metadata, the
//  selection flags — so the image landing re-evaluates that leaf and leaves this tile alone.
//

import SwiftUI

struct GalleryCell: View {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    let isCurrent: Bool
    let isRenaming: Bool
    let isStripping: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
            caption
        }
        .padding(3)
        .background(isSelected ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    /// The tile: the thumbnail leaf, layered with the badges that read the file's cached metadata
    /// and the chrome that reads its selection state. The layers live here rather than in the leaf
    /// so a thumbnail landing doesn't re-evaluate them.
    private var thumbnail: some View {
        GalleryThumbnailImage(file: file, playlist: playlist)
            // Metadata badges in three corners: dimensions top-right, size bottom-left,
            // running time bottom-right. Each is shown only once its field is cached, and only
            // for a type that carries it (images have no duration; audio has no gallery).
            .overlay(alignment: .topTrailing) {
                if let size = file.pixelSize { badge(size.dimensionsText) }
            }
            // The HDR marker, top-left, when the content's transfer is PQ/HLG (video) or the decode
            // carried HDR range (image). A quality marker, not a measurement, so it reads "HDR".
            .overlay(alignment: .topLeading) {
                if file.isHDR == true { pill(Text("HDR").bold()) }
            }
            // Cloud availability and on-disk size are conceptually paired, so the cloud badge
            // sits beside the size badge — shown (as its own pill) only when the file isn't local.
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    if file.cloudStatus.badgeSymbol != nil {
                        Button { appState.downloadFiles([file]) } label: {
                            pill(CloudStatusBadge(status: file.cloudStatus))
                        }
                        .buttonStyle(.plain)
                        .help("Download from iCloud")
                    }
                    if let bytes = file.fileSizeBytes { badge(bytes.formattedFileSize) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = file.duration { badge(duration.formattedDuration) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // The playback cursor is purple; a selected-but-not-current tile keeps the accent.
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: 3)
            }
            // A dimming scrim with a spinner while this cell's audio is being removed.
            .overlay {
                if isStripping {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.black.opacity(0.4))
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
    }

    @ViewBuilder
    private var caption: some View {
        if isRenaming {
            RenameFileField(text: $draftName, onCommit: onCommitRename, onCancel: onCancelRename)
        } else {
            Text(file.fileName)
                .font(.caption)
                // Always reserve two lines so a one-line name doesn't shrink the tile: every
                // cell (and its selection highlight) keeps a common height regardless of name length.
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// One thumbnail corner badge: a text pill. The dimensions, size, and duration badges.
    private func badge(_ text: String) -> some View { pill(Text(text)) }

    /// The dark rounded pill chrome, inset from the tile edge — a white monospaced caption or,
    /// for the cloud badge, a glyph. Shared by every corner badge.
    private func pill(_ content: some View) -> some View {
        content
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .padding(2)
    }

    /// Purple for the playback cursor, accent for a selected non-current tile, none otherwise.
    private var borderColor: Color {
        if isCurrent { return .playbackCursor }
        return isSelected ? .accentColor : .clear
    }
}
