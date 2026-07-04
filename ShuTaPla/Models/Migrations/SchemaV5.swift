//
//  SchemaV5.swift
//  ShuTaPla
//
//  The pre-index baseline — the shape every existing store carries, stamped `Schema.Version(5,0,0)`.
//  Its Playlist/PlaylistFile/Tag are pinned copies frozen *before* PlaylistFile's `#Index` and
//  before the `SchemaMarker` entity SchemaV6 adds. Pinning one model of the relationship component
//  drags the whole component, so its relationships resolve to same-version types;
//  AppStateModel/GlobalSettings carry no reference into it and reuse the live types. This is the
//  `from` side of the V5→V6 lightweight migration (see `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

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
        var preferences: PlaylistPreferences = PlaylistPreferences()
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
