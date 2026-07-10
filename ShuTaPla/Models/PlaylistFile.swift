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
    /// Indexes for the store-side sequence derivation (`ModelContext+Sequence.swift`). Every
    /// list/playback fetch filters on the owning `playlist` **and** `isSkipped` (both equality),
    /// then sorts by `sortOrder`; the triage filters and counts add `taggingStatusCode`. Leading
    /// each compound with `(playlist, isSkipped)` before the `sortOrder` sort turns each query into
    /// a contiguous, already-ordered index range with no per-row table lookups — `isSkipped` folded
    /// in rather than left a residual (which would force a row fetch just to read the boolean).
    /// `id` serves the single-file resolve. The tag filter joins the many-to-many junction, which no
    /// fetch index can cover; `Tag.normalizedName`'s uniqueness index and the `(playlist, isSkipped)`
    /// narrowing are what make it fast.
    #Index<PlaylistFile>(
        [\.playlist, \.isSkipped, \.sortOrder],
        [\.playlist, \.isSkipped, \.taggingStatusCode, \.sortOrder],
        [\.id]
    )

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

    /// Content-derived identity (`URL.contentFingerprint`): stable across rename/move and
    /// independent of the referencing folder, so it keys the thumbnail cache and marks the
    /// same media referenced by two playlists. Filled by the thumbnail producer on first
    /// gallery display; stays `nil` for a file never thumbnailed (a list-only audio file, or
    /// one never scrolled to).
    var fingerprint: String?

    /// On-disk modification date at the time the thumbnail producer last examined the file, cached
    /// alongside `fingerprint`. The staleness gate re-examines the file when this or `fileSizeBytes`
    /// drifts from disk; the `fingerprint` then decides whether the content actually changed. `nil`
    /// until first thumbnailed (a list-only audio file, or one never scrolled to, carries neither).
    var lastModified: Date?

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

    /// Runtime-only iCloud availability — derived from disk, never persisted. Routed through
    /// the model's own `@Observable` registrar so the live cloud feed's writes re-render every
    /// reader (badges, the playback gate): SwiftData's `@Model` macro wraps *persisted* stored
    /// properties in `_$observationRegistrar` but leaves a `@Transient` stored property
    /// un-tracked, so a plain `@Transient var` mutates invisibly to `withObservationTracking`.
    @Transient private var _cloudStatus: CloudStatus = .local
    @Transient var cloudStatus: CloudStatus {
        get {
            _$observationRegistrar.access(self, keyPath: \.cloudStatus)
            return _cloudStatus
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \.cloudStatus) {
                _cloudStatus = newValue
            }
        }
    }

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
