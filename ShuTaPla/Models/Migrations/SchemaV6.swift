//
//  SchemaV6.swift
//  ShuTaPla
//
//  The index baseline, stamped `Schema.Version(6,0,0)`: the shape every store carries after the
//  V5→V6 migration — PlaylistFile's `#Index` and the standalone `SchemaMarker` entity — but before
//  PlaylistFile's `fingerprint` column. Its Playlist/PlaylistFile/Tag are pinned copies frozen
//  *before* that column; pinning one model of the relationship component drags the whole component,
//  so its relationships resolve to same-version types. The value types its Playlist stores are pinned
//  as `Legacy` copies for the same reason. AppStateModel/GlobalSettings/SchemaMarker
//  carry no reference into it and reuse the live types. This is the `from` side of the V6→V7
//  lightweight migration (see `doc/versioning.md`).
//

import Foundation
import SwiftData

enum SchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self,
         SchemaMarker.self]
    }

    @Model
    final class Playlist {
        var id: UUID = UUID()
        var name: String = ""
        var folderBookmark: Data = Data()
        var folderPath: String = ""
        var mediaType: Legacy.MediaType = Legacy.MediaType.video
        var sortOrder: Int = 0
        var currentFileID: UUID?
        var playbackState: Legacy.PlaybackState = Legacy.PlaybackState.stopped
        var createdAt: Date = Date()
        var preferences: Legacy.Preferences = Legacy.Preferences()
        var filterState: Legacy.FilterState = Legacy.FilterState()
        var savedSearches: [Legacy.SavedSearch] = []
        var unfilteredResumeSortOrder: Int?
        var tagFrequency: [String: Int] = [:]

        @Relationship(deleteRule: .cascade, inverse: \PlaylistFile.playlist)
        var files: [PlaylistFile] = []

        init(name: String, folderBookmark: Data, folderPath: String, mediaType: Legacy.MediaType, sortOrder: Int = 0) {
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
        #Index<PlaylistFile>(
            [\.playlist, \.isSkipped, \.sortOrder],
            [\.playlist, \.isSkipped, \.taggingStatusCode, \.sortOrder],
            [\.id]
        )

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
