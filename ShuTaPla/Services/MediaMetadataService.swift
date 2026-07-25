//
//  MediaMetadataService.swift
//  ShuTaPla
//
//  Media-metadata extraction for the Manager's list mode: running time, pixel
//  dimensions, and on-disk size. The first time a file is displayed its metadata is
//  read off the main actor — via AVFoundation, falling back to libmpv for containers
//  AVFoundation can't open (webm, mkv, …), and via `CGImageSource` for stills — then
//  cached on the model (`PlaylistFile`) so every later display and launch is instant.
//
//  The public entry point reads the model on the main actor, hands Sendable values
//  (bookmark, relative path, media type) to a `nonisolated` worker, and folds the
//  result back onto the model through the shared `merge` sink.
//

import Foundation
import AVFoundation
import Observation
import SwiftData

@MainActor
@Observable
final class MediaMetadataService {

    /// The metadata for `file`, read and cached on first request. Serves the model's
    /// cached bundle when every field this file's type can carry is already known;
    /// otherwise opens the file once off the main actor, merges whatever it found onto
    /// the model, and returns the updated bundle.
    func metadata(for file: PlaylistFile, in playlist: Playlist, folderURL: URL? = nil) async -> MediaMetadata {
        if file.hasCompleteMetadata(for: playlist.mediaType) { return file.cachedMetadata }
        // An evicted file isn't opened — extraction would read bytes that aren't local. Serve the
        // cached bundle (possibly partial); its next arrival as `.local` re-triggers this read.
        guard file.cloudStatus == .local else { return file.cachedMetadata }

        let found = await Self.extract(
            folderURL: folderURL,
            bookmark: playlist.folderBookmark,
            relativePath: file.relativePath,
            mediaType: playlist.mediaType,
            isSkipped: file.isSkipped
        )
        file.merge(found)
        // Persist the freshly extracted facts immediately: an autosave-pending merge is discarded if a
        // later `includePendingChanges = false` object fetch refaults the record before it flushes.
        file.trySave()
        return file.cachedMetadata
    }

    /// Resolves the file and reads its metadata: on-disk size for every type, plus
    /// duration and dimensions from the type-appropriate decoder. A skipped file is
    /// wrong-type for its playlist, so the decoder can't read it — `isSkipped` records
    /// only the size and skips the decode. Returns an empty bundle when the file is gone.
    ///
    /// `@concurrent` so the resolve + decode lands on the cooperative pool: under
    /// MainActor-default isolation a plain `nonisolated async` would run on the caller's
    /// actor (the main actor for `metadata(for:in:)`), freezing the UI while the file
    /// list populates uncached metadata.
    @concurrent nonisolated static func extract(folderURL: URL? = nil, bookmark: Data, relativePath: String, mediaType: MediaType, isSkipped: Bool) async -> MediaMetadata {
        (try? await BookmarkService.withResolvedFile(folder: folderURL, bookmark: bookmark, relativePath: relativePath) { fileURL in
            var metadata = MediaMetadata()
            metadata.fileSizeBytes = fileURL.fileSizeBytes
            // The staleness baseline, read on every open for every type — before the skip guard, so even
            // a skipped file (size-only) carries one for the scan and preview to compare against.
            metadata.lastModified = fileURL.contentModificationDate
            guard !isSkipped else { return metadata }
            switch mediaType {
            case .image:
                if let size = fileURL.imagePixelSize {
                    metadata.width = size.width
                    metadata.height = size.height
                }
            case .video, .audio:
                let av = await avMetadata(at: fileURL, wantsDimensions: mediaType == .video)
                metadata.duration = av.duration
                metadata.width = av.width
                metadata.height = av.height
                metadata.hdrGamma = av.gamma
                metadata.hdrPrimaries = av.primaries
                // libmpv reads what AVFoundation couldn't open (webm, mkv), filling any gap —
                // including the colour tags, which come from its `video-params` when present.
                if metadata.duration == nil || (mediaType == .video && (metadata.width == nil || metadata.height == nil)) {
                    let mpv = await MPVThumbnailer.metadata(at: fileURL)
                    metadata.duration = metadata.duration ?? mpv.duration
                    metadata.width = metadata.width ?? mpv.width
                    metadata.height = metadata.height ?? mpv.height
                    metadata.hdrGamma = metadata.hdrGamma ?? mpv.hdrGamma
                    metadata.hdrPrimaries = metadata.hdrPrimaries ?? mpv.hdrPrimaries
                }
                // Settle the badge fact once the file opened as video (dimensions read): a positive
                // PQ/HLG gamma is HDR, an absent or SDR gamma is a determined `false` (not `nil`), so
                // completeness stops re-examining it. A file that wouldn't open leaves it `nil`.
                if mediaType == .video, metadata.width != nil {
                    metadata.isHDR = VideoColorTags.isHDR(gamma: metadata.hdrGamma)
                }
            }
            return metadata
        }) ?? MediaMetadata()
    }

    /// The asset's duration, and — when `wantsDimensions` (video) — its display size and mpv-style
    /// colour tags. A moov-atom read: no frame is decoded. `nil` fields when AVFoundation can't read
    /// them (the webm/mkv case, where the caller falls back to libmpv).
    @concurrent private nonisolated static func avMetadata(at url: URL, wantsDimensions: Bool) async -> (duration: TimeInterval?, width: Int?, height: Int?, gamma: String?, primaries: String?) {
        let (duration, size, gamma, primaries) = await AVURLAsset(url: url).videoMetadata(wantsVideo: wantsDimensions)
        return (duration, size?.width, size?.height, gamma, primaries)
    }
}
