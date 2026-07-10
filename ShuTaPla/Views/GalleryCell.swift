//
//  GalleryCell.swift
//  ShuTaPla
//
//  One gallery tile in the Manager center: an async-loaded thumbnail with the filename
//  (or an inline rename field) beneath it, plus a selection highlight and metadata badges.
//  The gallery presentation of `FileCollectionView`; the list presentation's row is
//  `FileRowView`.
//

import SwiftUI
import AppKit

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

    @Environment(ThumbnailService.self) private var thumbnails
    @Environment(MediaMetadataService.self) private var metadataService
    @State private var image: NSImage?

    /// Longest-edge size in pixels: the cell's point size scaled for Retina.
    private let maxPixelSize = AppConstants.galleryThumbnailPixelSize

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
            caption
        }
        .padding(3)
        .background(isSelected ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // Generation is deferrable background work, so it runs at `.utility` QoS
        // rather than the default user-initiated: the encoder blocks its worker
        // thread on CoreMedia, and a lower band keeps that off the priority path.
        .task(id: thumbnailKey, priority: .utility) {
            // A previously generated thumbnail is served synchronously, so seen
            // cells don't flash a placeholder while scrolling; otherwise generate it
            // off the main actor. Generation reports the media's metadata in the same
            // result — the decode already determined duration and dimensions, and the
            // open read the file size — so the badge and cached shape appear with the
            // thumbnail rather than after a second pass. It's folded onto the model,
            // which the badge reads directly.
            if let cached = thumbnails.cachedThumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize) {
                image = cached
            } else {
                let result = await thumbnails.thumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize)
                // Generation runs off-actor and always completes — cancellation can't abort it,
                // it only flips `Task.isCancelled`. Its result must therefore be handled either
                // way: the thumbnail is already written to disk keyed by its fingerprint, and this
                // merge is what records that fingerprint on the model. Skipping it would strand the
                // just-written thumbnail with no live record, so the orphan sweep deletes it.
                file.merge(result.metadata)
                // The guard protects *only* the on-screen image: on fast scroll/recycle this cell
                // may already be showing a different file by the time generation lands, so don't
                // paint this (now stale) thumbnail into it.
                guard !Task.isCancelled else { return }
                image = result.image
            }
            // A thumbnail served from cache (disk or memory) carries no decoded metadata,
            // and a fresh decode fills only what its type carries; open the file once more
            // for anything this type still needs (dimensions on a cache hit, size for a
            // memory hit), matching what the list view reads.
            if !file.hasCompleteMetadata(for: playlist.mediaType) {
                _ = await metadataService.metadata(for: file, in: playlist)
            }
        }
    }

    /// A uniform 4:3 tile: the rectangle fills the (equal) grid-column width, so
    /// every thumbnail is the same size regardless of the source's dimensions.
    /// The image fills and is center-cropped to the tile.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: playlist.mediaType == .video ? "film" : "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            // Metadata badges in three corners: dimensions top-right, size bottom-left,
            // running time bottom-right. Each is shown only once its field is cached, and only
            // for a type that carries it (images have no duration; audio has no gallery).
            .overlay(alignment: .topTrailing) {
                if let size = file.pixelSize { badge(size.dimensionsText) }
            }
            // Cloud availability and on-disk size are conceptually paired, so the cloud badge
            // sits beside the size badge — shown (as its own pill) only when the file isn't local.
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    if file.cloudStatus.badgeSymbol != nil {
                        pill(CloudStatusBadge(status: file.cloudStatus))
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

    /// Reload when the file is replaced or renamed (path change).
    private var thumbnailKey: String { "\(file.id)|\(file.relativePath)" }
}
