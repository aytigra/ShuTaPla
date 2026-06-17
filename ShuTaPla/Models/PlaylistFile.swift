//
//  PlaylistFile.swift
//  ShuTaPla
//
//  A single media file within a playlist. The file on disk is the source of
//  truth; this entity is a lightweight, denormalized index into it.
//

import Foundation
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

    /// Tags parsed from the filename, cached for filtering.
    var tags: [String] = []

    var taggingStatus: TaggingStatus = TaggingStatus.untagged

    /// Unsupported / other-media-type file. Kept for the skipped-files filter,
    /// never played or shuffled in.
    var isSkipped: Bool = false

    /// For file-position persistence (seconds).
    var lastPosition: TimeInterval?

    /// Total running time in seconds, extracted on first display and cached here.
    /// `nil` until known; always `nil` for image files, which have no timeline.
    var duration: TimeInterval?

    /// Shuffled order within the playlist.
    var sortOrder: Int = 0

    /// Owning playlist (inverse of `Playlist.files`).
    var playlist: Playlist?

    /// Runtime-only iCloud availability — derived from disk, never persisted.
    @Transient var cloudStatus: CloudStatus = .local

    init(
        relativePath: String,
        fileName: String,
        tags: [String] = [],
        taggingStatus: TaggingStatus = .untagged,
        isSkipped: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.relativePath = relativePath
        self.fileName = fileName
        self.tags = tags
        self.taggingStatus = taggingStatus
        self.isSkipped = isSkipped
        self.sortOrder = sortOrder
    }
}
