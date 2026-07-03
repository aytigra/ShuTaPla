//
//  SchemaV4.swift
//  ShuTaPla
//
//  The pre-gallery-width schema, pinning the stored shape before `Playlist.preferences` gained
//  its `galleryMinItemWidth` field.
//

import Foundation
import SwiftData

/// The pre-gallery-width schema: `Playlist.preferences` still had the six-field
/// `LegacySchema.PlaylistPreferences` composite (no `galleryMinItemWidth`). Because that field
/// lives inside a single Codable struct property — stored as a structured composite attribute —
/// adding it changes `Playlist`'s hash, so this version reconstructs `Playlist` (and its whole
/// relationship component, `PlaylistFile`↔`Tag`) to pin the old shape. `PlaylistFile` already
/// carries the `width`/`height`/`fileSizeBytes` columns added at V4. `AppStateModel`/`GlobalSettings`
/// carry no `PlaylistFile` reference, so they reuse the live types.
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self]
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
        var preferences: LegacySchema.PlaylistPreferences = LegacySchema.PlaylistPreferences()
        var filterState: FilterState = FilterState()
        var savedSearches: [SavedSearch] = []
        var unfilteredResumeSortOrder: Int?
        var tagFrequency: [String: Int] = [:]

        @Relationship(deleteRule: .cascade, inverse: \PlaylistFile.playlist)
        var files: [PlaylistFile] = []

        init(name: String, folderBookmark: Data, folderPath: String, mediaType: MediaType, sortOrder: Int = 0) {
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
        @Relationship(inverse: \Tag.files) var tags: [Tag] = []
        var taggingStatusCode: Int = TaggingStatus.untagged.code
        var isSkipped: Bool = false
        var lastPosition: TimeInterval?
        var duration: TimeInterval?
        var width: Int?
        var height: Int?
        var fileSizeBytes: Int?
        var sortOrder: Int = 0
        var playlist: Playlist?

        init(relativePath: String, fileName: String, isSkipped: Bool = false, sortOrder: Int = 0) {
            self.id = UUID()
            self.relativePath = relativePath
            self.fileName = fileName
            self.isSkipped = isSkipped
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class Tag {
        @Attribute(.unique) var normalizedName: String = ""
        var name: String = ""
        @Relationship var files: [PlaylistFile] = []

        init(name: String, normalizedName: String) {
            self.name = name
            self.normalizedName = normalizedName
        }
    }
}
