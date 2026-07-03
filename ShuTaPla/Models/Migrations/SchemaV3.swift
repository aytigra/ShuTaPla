//
//  SchemaV3.swift
//  ShuTaPla
//
//  The pre-media-metadata schema, pinning the stored shape before `PlaylistFile` gained its
//  `width`/`height`/`fileSizeBytes` columns.
//

import Foundation
import SwiftData

/// The pre-media-metadata schema: `PlaylistFile` had no `width`/`height`/`fileSizeBytes` columns.
/// `Playlist`/`Tag` are unchanged from V4 but, as the other half of `PlaylistFile`'s relationship
/// graph, are reconstructed alongside it to keep this version's models self-referential.
/// `AppStateModel`/`GlobalSettings` carry no `PlaylistFile` reference, so they reuse the live types.
enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

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
