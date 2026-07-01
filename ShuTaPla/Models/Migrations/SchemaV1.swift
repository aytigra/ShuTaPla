//
//  SchemaV1.swift
//  ShuTaPla
//
//  The pre-`Tag` schema, pinning the stored shape when filename tags were an inline `[String]`.
//

import Foundation
import SwiftData

/// The pre-`Tag` schema: filename tags were an inline `[String]` and tagging status a
/// stored enum, with no `Tag` entity. `AppStateModel`/`GlobalSettings` never referenced
/// `PlaylistFile`, so they are unchanged and reused from the live types; `Playlist` and
/// `PlaylistFile` are reconstructed here only to pin this version's stored shape — they
/// declare just the persisted properties (computed members and methods don't affect the
/// store's version hashes).
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, AppStateModel.self, GlobalSettings.self]
    }

    @Model
    final class Playlist {
        var id: UUID = UUID()
        var name: String = ""
        var folderBookmark: Data = Data()
        var folderPath: String = ""
        var mediaType: MediaType = MediaType.video
        var sortOrder: Int = 0
        var currentFileID: UUID?
        var playbackState: PlaybackState = PlaybackState.stopped
        var createdAt: Date = Date()
        var preferences: PlaylistPreferences = PlaylistPreferences()
        var filterState: FilterState = FilterState()
        var savedSearches: [SavedSearch] = []
        var tagFrequency: [String: Int] = [:]

        @Relationship(deleteRule: .cascade, inverse: \PlaylistFile.playlist)
        var files: [PlaylistFile] = []

        init(
            name: String,
            folderBookmark: Data,
            folderPath: String,
            mediaType: MediaType,
            sortOrder: Int = 0
        ) {
            self.id = UUID()
            self.name = name
            self.folderBookmark = folderBookmark
            self.folderPath = folderPath
            self.mediaType = mediaType
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class PlaylistFile {
        var id: UUID = UUID()
        var relativePath: String = ""
        var fileName: String = ""
        var tags: [String] = []
        var taggingStatus: TaggingStatus = TaggingStatus.untagged
        var isSkipped: Bool = false
        var lastPosition: TimeInterval?
        var duration: TimeInterval?
        var sortOrder: Int = 0
        var playlist: Playlist?

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
}
