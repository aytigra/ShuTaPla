//
//  FileGalleryView.swift
//  ShuTaPla
//
//  The Manager center gallery: a `LazyVGrid` of thumbnail cells over the same
//  filtered files as the list view (`AppState.managerFiles`). Selection, rename,
//  scroll, and the context menu are handled by the shared `FileCollectionView`;
//  this names the gallery presentation and supplies the cell. Each cell loads its
//  thumbnail asynchronously and cancels the load when scrolled off-screen.
//

import SwiftUI
import AppKit

struct FileGalleryView: View {
    let playlist: Playlist
    let confirmDelete: ([PlaylistFile]) -> Void
    let reportError: (String) -> Void

    var body: some View {
        FileCollectionView(
            playlist: playlist,
            layout: .gallery,
            confirmDelete: confirmDelete,
            reportError: reportError
        ) { config in
            GalleryCell(
                file: config.file,
                playlist: config.playlist,
                isSelected: config.isSelected,
                isRenaming: config.isRenaming,
                isStripping: config.isStripping,
                draftName: config.draftName,
                onCommitRename: config.onCommitRename,
                onCancelRename: config.onCancelRename
            )
        }
    }
}

/// One gallery tile: an async-loaded thumbnail with the filename (or an inline
/// rename field) beneath it, plus a selection highlight.
private struct GalleryCell: View {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    let isRenaming: Bool
    let isStripping: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(ThumbnailService.self) private var thumbnails
    @Environment(DurationService.self) private var durations
    @State private var image: NSImage?

    /// Longest-edge size in pixels: the cell's point size scaled for Retina.
    private let maxPixelSize = AppConstants.galleryThumbnailPixelSize

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            caption
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Generation is deferrable background work, so it runs at `.utility` QoS
        // rather than the default user-initiated: the encoder blocks its worker
        // thread on CoreMedia, and a lower band keeps that off the priority path.
        .task(id: thumbnailKey, priority: .utility) {
            // A previously generated thumbnail is served synchronously, so seen
            // cells don't flash a placeholder while scrolling; otherwise generate it
            // off the main actor. Generation reports the video's length in the same
            // result — the decode already determined it — so the badge appears with
            // the thumbnail rather than after a second pass. The length is persisted
            // on the model, which the badge reads directly.
            if let cached = thumbnails.cachedThumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize) {
                image = cached
            } else {
                let result = await thumbnails.thumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize)
                // On fast scroll/recycle this cell may already be showing a different file
                // by the time generation lands; don't paint the stale image into it.
                guard !Task.isCancelled else { return }
                image = result.image
                if let seconds = result.duration { file.duration = seconds }
            }
            // A thumbnail served from cache (disk or memory) carries no length, so
            // read it once if the model still lacks it. Images have no timeline.
            if playlist.mediaType == .video, file.duration == nil {
                _ = await durations.duration(for: file, in: playlist)
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
            .overlay(alignment: .bottomTrailing) {
                if let duration = file.duration {
                    Text(duration.formattedDuration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
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
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Reload when the file is replaced or renamed (path change).
    private var thumbnailKey: String { "\(file.id)|\(file.relativePath)" }
}
