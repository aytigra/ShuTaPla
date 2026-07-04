//
//  PlaylistFile.swift
//  ShuTaPla
//
//  A single media file within a playlist. The file on disk is the source of
//  truth; this entity is a lightweight, denormalized index into it.
//

import Foundation
import CoreGraphics
import SwiftData

@Model
final class PlaylistFile {
    /// Stable identity. Survives Update prune/append (an index would not).
    var id: UUID = UUID()

    /// Path relative to the playlist's root folder, so the references stay
    /// valid if the folder moves and its bookmark is refreshed.
    var relativePath: String = ""

    /// Just the filename component (with extension).
    var fileName: String = ""

    /// Tags carried by this file — a shared, normalized relationship so the tag filter is a
    /// store-side `#Predicate`. Mirrors the filename's parsed tokens; populated on scan/rename.
    @Relationship(inverse: \Tag.files) var tags: [Tag] = []

    /// Predicate-queryable discriminator for `taggingStatus`. `taggingStatus` is the API.
    var taggingStatusCode: Int = TaggingStatus.untagged.code

    /// The parse result for this file's filename, backed by the scalar discriminator column.
    var taggingStatus: TaggingStatus {
        get { TaggingStatus(code: taggingStatusCode) }
        set { taggingStatusCode = newValue.code }
    }

    /// The tag tokens' display names, in filename order — the source of truth for display.
    /// The `tags` relationship is an unordered set holding the same tokens (for store-side
    /// matching); the filename fixes their order, so chips render the same every time.
    var tagNames: [String] { TagParser.fields(for: fileName).0 }

    /// Unsupported / other-media-type file. Kept for the skipped-files filter,
    /// never played or shuffled in.
    var isSkipped: Bool = false

    /// For file-position persistence (seconds).
    var lastPosition: TimeInterval?

    /// Total running time in seconds, extracted on first display and cached here.
    /// `nil` until known; always `nil` for image files, which have no timeline.
    var duration: TimeInterval?

    /// Pixel dimensions, extracted on first display and cached here (mirror mpv
    /// `dwidth`/`dheight` and rounded AVFoundation `naturalSize`). `nil` until known.
    var width: Int?
    var height: Int?

    /// On-disk size in bytes, read on first display and cached here. `nil` until known.
    var fileSizeBytes: Int?

    /// Pixel dimensions as a size, available only once both `width` and `height` are known.
    var pixelSize: CGSize? {
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The canonical tag display names this file contributes to its playlist's `tagFrequency`:
    /// its tags' names, or none when skipped (the cache counts only playable files). An edit's
    /// delta is the change in this set, applied by `ModelContext.applyTagFrequencyDelta`.
    var tagFrequencyNames: Set<String> {
        isSkipped ? [] : Set(tags.map(\.name))
    }

    /// Shuffled order within the playlist.
    var sortOrder: Int = 0

    /// Owning playlist (inverse of `Playlist.files`).
    var playlist: Playlist?

    /// Runtime-only iCloud availability — derived from disk, never persisted.
    @Transient var cloudStatus: CloudStatus = .local

    /// Tags are a relationship resolved against a `ModelContext`, so they're assigned after
    /// insert (via `ModelContext.tags(named:)`) rather than passed here.
    init(
        relativePath: String,
        fileName: String,
        taggingStatus: TaggingStatus = .untagged,
        isSkipped: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.relativePath = relativePath
        self.fileName = fileName
        self.taggingStatus = taggingStatus
        self.isSkipped = isSkipped
        self.sortOrder = sortOrder
    }
}
