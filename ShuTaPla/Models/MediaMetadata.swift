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

    /// On-disk modification date, filled only by the thumbnail producer alongside `fingerprint`.
    /// Half of the staleness gate ("re-examine this file?"): a change here or in `fileSizeBytes`
    /// triggers a fingerprint recompute. Travels with `fingerprint` because the gate needs a prior
    /// fingerprint to invalidate, so a file first seen in list mode carries neither.
    var lastModified: Date?
}

extension PlaylistFile {
    /// The metadata currently cached on the model.
    var cachedMetadata: MediaMetadata {
        MediaMetadata(duration: duration, width: width, height: height, fileSizeBytes: fileSizeBytes,
                      fingerprint: fingerprint, lastModified: lastModified)
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
        if let lastModified = metadata.lastModified { self.lastModified = lastModified }
    }

    /// Clears every derived fact so the next display re-extracts from scratch: an unconditional reset
    /// of `duration`, `width`, `height`, `fileSizeBytes`, `lastModified`, **and** `fingerprint`. Writes
    /// the stored properties directly — not through `merge`, whose `nil` fields are no-ops — so the
    /// record truly forgets. Clearing the fingerprint costs no re-render: the disk thumbnail cache is
    /// content-keyed, so unchanged bytes recompute the same fingerprint and hit it.
    func invalidateMetadata() {
        duration = nil
        width = nil
        height = nil
        fileSizeBytes = nil
        lastModified = nil
        fingerprint = nil
    }

    /// Clears the cached metadata when the file's on-disk `size` or `modified` diverges from the cached
    /// baseline (`fileSizeBytes` / `lastModified`) — the general staleness gate the scan and preview run.
    /// A no-op when there's no baseline yet (`lastModified == nil`: nothing cached to invalidate) or when
    /// a fact couldn't be read from disk (`nil`), so a failed stat never clears good metadata on a false
    /// divergence. Returns whether it invalidated.
    @discardableResult
    func invalidateMetadataIfStale(size: Int?, modified: Date?) -> Bool {
        guard lastModified != nil else { return false }
        let diverged = (size != nil && size != fileSizeBytes) || (modified != nil && modified != lastModified)
        guard diverged else { return false }
        invalidateMetadata()
        return true
    }

    /// Whether every field this file's type can carry is already cached, so re-extracting
    /// would open the file only to learn nothing new. Audio carries no pixel dimensions;
    /// images no duration. A skipped file is wrong-type for its playlist, so its
    /// duration/dimensions can never be read — only size is recorded, so size alone completes it.
    ///
    /// Size and `lastModified` (the staleness baseline) are required for every type: a pre-mtime
    /// cached row reads incomplete, so its next display re-extracts and gains a baseline.
    func hasCompleteMetadata(for mediaType: MediaType) -> Bool {
        guard fileSizeBytes != nil, lastModified != nil else { return false }
        if isSkipped { return true }
        switch mediaType {
        case .video: return duration != nil && width != nil && height != nil
        case .audio: return duration != nil
        case .image: return width != nil && height != nil
        }
    }
}
