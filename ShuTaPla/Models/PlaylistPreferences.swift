//
//  PlaylistPreferences.swift
//  ShuTaPla
//
//  Embedded value type stored on `Playlist`. SwiftData encodes Codable
//  properties to JSON automatically, so this avoids a separate entity and
//  is removed with its playlist on cascade delete.
//

import Foundation

nonisolated struct PlaylistPreferences: Codable, Sendable, Equatable {
    /// 0.0–1.0. Per-playlist output level.
    var volume: Float = 1.0
    var slideshowEnabled: Bool = false
    /// `nil` falls back to `GlobalSettings.defaultSlideshowInterval`.
    var slideshowInterval: TimeInterval?
    /// `nil` falls back to `GlobalSettings.defaultImageFitMode`.
    var imageFitMode: ImageFitMode?
    /// `nil` falls back to `GlobalSettings.defaultFilePositionPersistence`.
    var filePositionPersistence: Bool?
    var viewMode: ViewMode = .list
    /// `nil` falls back to `FileCollectionLayout.galleryMinItemWidth`. The gallery's
    /// adaptive minimum tile width; the maximum is derived from it (see `gridMetrics`).
    var galleryMinItemWidth: Double?

    init() {}
}
