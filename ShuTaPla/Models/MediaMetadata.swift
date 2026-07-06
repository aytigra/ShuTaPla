//
//  MediaMetadata.swift
//  ShuTaPla
//
//  The bundle of file facts read once off the main actor on first display and cached on
//  `PlaylistFile`: running time, pixel dimensions, and on-disk size. Produced by the two
//  file opens that already happen on display — `MediaMetadataService` (list mode) and the
//  thumbnailer (gallery mode) — and folded onto the model through one shared sink so the
//  two producers never overwrite each other's findings.
//

import Foundation

/// Metadata cached on a `PlaylistFile`. Each field is `nil` until determined: `duration`
/// stays `nil` for images (no timeline); `width`/`height` stay `nil` for audio (no picture).
nonisolated struct MediaMetadata: Sendable {
    var duration: TimeInterval?
    var width: Int?
    var height: Int?
    var fileSizeBytes: Int?

    /// Content fingerprint, filled only by the thumbnail producer (the one path that keys the
    /// cache by it). The list-mode extractor never sets it, so it stays `nil` there — like
    /// `duration` for an image.
    var fingerprint: String?
}

extension PlaylistFile {
    /// The metadata currently cached on the model.
    var cachedMetadata: MediaMetadata {
        MediaMetadata(duration: duration, width: width, height: height, fileSizeBytes: fileSizeBytes,
                      fingerprint: fingerprint)
    }

    /// Folds `metadata` onto the model, coalescing non-`nil` fields: a freshly-read value overwrites
    /// what's cached, while a field the producer didn't read (`nil`) leaves the cached value intact.
    /// `nil` means "not read", never "the value is nil" — so a disk-cache hit (which reports only
    /// size + fingerprint, no decode) preserves a prior duration/dimensions, while a fresh render or
    /// a size-mismatch re-derivation refreshes every stale field on the record.
    func merge(_ metadata: MediaMetadata) {
        if let duration = metadata.duration { self.duration = duration }
        if let width = metadata.width { self.width = width }
        if let height = metadata.height { self.height = height }
        if let fileSizeBytes = metadata.fileSizeBytes { self.fileSizeBytes = fileSizeBytes }
        if let fingerprint = metadata.fingerprint { self.fingerprint = fingerprint }
    }

    /// Whether every field this file's type can carry is already cached, so re-extracting
    /// would open the file only to learn nothing new. Audio carries no pixel dimensions;
    /// images no duration.
    func hasCompleteMetadata(for mediaType: MediaType) -> Bool {
        guard fileSizeBytes != nil else { return false }
        switch mediaType {
        case .video: return duration != nil && width != nil && height != nil
        case .audio: return duration != nil
        case .image: return width != nil && height != nil
        }
    }
}
