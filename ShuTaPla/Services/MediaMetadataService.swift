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

@MainActor
@Observable
final class MediaMetadataService {

    /// The metadata for `file`, read and cached on first request. Serves the model's
    /// cached bundle when every field this file's type can carry is already known;
    /// otherwise opens the file once off the main actor, merges whatever it found onto
    /// the model, and returns the updated bundle.
    func metadata(for file: PlaylistFile, in playlist: Playlist) async -> MediaMetadata {
        if file.hasCompleteMetadata(for: playlist.mediaType) { return file.cachedMetadata }

        let found = await Self.extract(
            bookmark: playlist.folderBookmark,
            relativePath: file.relativePath,
            mediaType: playlist.mediaType
        )
        file.merge(found)
        return file.cachedMetadata
    }

    /// Resolves the file and reads its metadata: on-disk size for every type, plus
    /// duration and dimensions from the type-appropriate decoder. Returns an empty
    /// bundle when the file is gone.
    ///
    /// `@concurrent` so the resolve + decode lands on the cooperative pool: under
    /// MainActor-default isolation a plain `nonisolated async` would run on the caller's
    /// actor (the main actor for `metadata(for:in:)`), freezing the UI while the file
    /// list populates uncached metadata.
    @concurrent nonisolated static func extract(bookmark: Data, relativePath: String, mediaType: MediaType) async -> MediaMetadata {
        (try? await BookmarkService.withResolvedFile(bookmark: bookmark, relativePath: relativePath) { fileURL in
            var metadata = MediaMetadata()
            metadata.fileSizeBytes = fileURL.fileSizeBytes
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
                // libmpv reads what AVFoundation couldn't open (webm, mkv), filling any gap.
                if metadata.duration == nil || (mediaType == .video && (metadata.width == nil || metadata.height == nil)) {
                    let mpv = await MPVThumbnailer.metadata(at: fileURL)
                    metadata.duration = metadata.duration ?? mpv.duration
                    metadata.width = metadata.width ?? mpv.width
                    metadata.height = metadata.height ?? mpv.height
                }
            }
            return metadata
        }) ?? MediaMetadata()
    }

    /// The asset's duration, and — when `wantsDimensions` — its display size. A moov-atom
    /// read: no frame is decoded. `nil` fields when AVFoundation can't read them (the
    /// webm/mkv case, where the caller falls back to libmpv).
    @concurrent private nonisolated static func avMetadata(at url: URL, wantsDimensions: Bool) async -> (duration: TimeInterval?, width: Int?, height: Int?) {
        let asset = AVURLAsset(url: url)
        let duration = await asset.playableDuration()
        guard wantsDimensions, let size = await asset.displayPixelSize() else { return (duration, nil, nil) }
        return (duration, size.width, size.height)
    }
}
