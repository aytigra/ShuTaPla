//
//  GalleryThumbnailImage.swift
//  ShuTaPla
//
//  The image surface of a gallery tile: the 4:3 rectangle, the thumbnail drawn into it, and the
//  generation that fills it. It owns the loaded image as `@State`, so the thumbnail landing
//  invalidates only this leaf. `GalleryCell` hangs the badges, border and scrim on top; those belong
//  to the tile's view value, so they are not re-evaluated when the image arrives — which is the whole
//  point of the split, since on a settled library the image is the only thing a scroll changes.
//

import SwiftUI
import AppKit

struct GalleryThumbnailImage: View {
    let file: PlaylistFile
    let playlist: Playlist

    @Environment(ThumbnailService.self) private var thumbnails
    @Environment(MediaMetadataService.self) private var metadataService
    @Environment(HDRCache.self) private var hdrCache
    // The surface's pre-resolved folder URL, when it holds a scoped-access session open. Passed into
    // the services so generation/metadata append the relative path instead of resolving per file.
    @Environment(\.browsingFolderURL) private var browsingFolderURL
    @State private var image: NSImage?

    /// Longest-edge size in pixels: the cell's point size scaled for Retina.
    private let maxPixelSize = AppConstants.galleryThumbnailPixelSize

    /// A uniform 4:3 tile: the rectangle fills the (equal) grid-column width, so
    /// every thumbnail is the same size regardless of the source's dimensions.
    /// The image fills and is center-cropped to the tile — the crop is the caller's
    /// `clipShape`, which also clips the badges it layers on.
    var body: some View {
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
            // Generation is deferrable background work, so it runs at `.utility` QoS
            // rather than the default user-initiated: the encoder blocks its worker
            // thread on CoreMedia, and a lower band keeps that off the priority path.
            .task(id: thumbnailKey, priority: .utility) {
                // Generation reports the media's metadata in the same result — the decode
                // already determined duration and dimensions, and the open read the file size —
                // so the badge and cached shape appear with the thumbnail rather than after a
                // second pass. It's folded onto the model, which the badge reads directly.
                let result = await thumbnails.thumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize, folderURL: browsingFolderURL)
                // Generation runs off-actor and always completes — cancellation can't abort it, it
                // only flips `Task.isCancelled` — so its result is normally recorded either way: the
                // thumbnail is already on disk keyed by its fingerprint, and this records that
                // fingerprint on the model. The exception is a file trashed-and-saved while the decode
                // ran: its row is gone, so any persisted write below would trap. Skip the record on an
                // deleted file — guarding on the row's existence, not cancellation, so a merely
                // cancelled-but-live file still records — and let the orphan sweep reclaim the
                // now-recordless thumbnail.
                guard file.existsInStore else { return }
                recordMetadata(result.metadata)
                // A fresh decode also determined the file's HDR fact (image range or video colour
                // tags); route it through the sink, the sole writer of the persisted HDR columns. A
                // cache-served thumbnail carries no finding (`nil`), so a settled value is kept.
                if let hdr = result.hdr { hdrCache.record(hdr, for: file) }
                // The guard protects *only* the on-screen image: on fast scroll/recycle this cell
                // may already be showing a different file by the time generation lands, so don't
                // paint this (now stale) thumbnail into it.
                guard !Task.isCancelled else { return }
                image = result.image
                // A thumbnail served from the disk cache carries no decoded metadata, and a fresh
                // decode fills only what its type carries; open the file once more for anything
                // this type still needs (dimensions on a cache hit), matching what the list view
                // reads.
                if !file.hasCompleteMetadata(for: playlist.mediaType) {
                    _ = await metadataService.metadata(for: file, in: playlist, folderURL: browsingFolderURL)
                }
            }
    }

    /// Folds the generation's metadata onto the model and persists it. The save matters for the
    /// `fingerprint`: the thumbnail decode is its sole producer (the list read never keys the cache)
    /// and it doesn't gate completeness, so — unlike the dimensions the list producer re-derives and
    /// saves — an unsaved merge here would be refaulted away by the next `includePendingChanges = false`
    /// object fetch (a cloud reconcile, a preview's folder monitor), stranding the just-written
    /// thumbnail with no live record for the orphan sweep to spare. HDR rides through `HDRCache`, which
    /// persists on its own. A scroll back over cached files re-states facts every record already
    /// holds, which `merge` drops — leaving the context clean, so `trySave` costs nothing.
    func recordMetadata(_ metadata: MediaMetadata) {
        file.merge(metadata)
        file.trySave()
    }

    /// Reload when the file is replaced or renamed (path change), when its bytes arrive from the
    /// cloud (`cloudStatus` flips to `.local`) so the tile regenerates the thumbnail the evicted pass
    /// skipped, and when its `fingerprint` is cleared — an external staleness invalidation (scan or
    /// strip) drops it, and tracking it here re-fires this cell's generation for an instant refresh.
    /// Keyed on local-ness, not the full status, so it re-fires only on that boundary.
    var thumbnailKey: String {
        "\(file.id)|\(file.relativePath)|\(file.cloudStatus == .local)|\(file.fingerprint ?? "")"
    }
}
