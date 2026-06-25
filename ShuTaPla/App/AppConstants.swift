//
//  AppConstants.swift
//  ShuTaPla
//
//  Extension maps, thresholds, and other magic numbers. `nonisolated` so the
//  file-system actor can read them off the main actor.
//

import Foundation

nonisolated enum AppConstants {
    static let videoExtensions: Set<String> = ["mp4", "webm", "mov", "avi", "mkv", "m4v"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "jxl", "gif", "heic", "heif", "webp", "tiff", "bmp"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "aiff", "wma"]

    /// Selectable slideshow intervals (seconds), shared by the global Settings default picker
    /// and the per-playlist interval selectors so they always offer the same choices.
    static let slideshowIntervals: [TimeInterval] = [3, 5, 10, 15, 30]

    /// A type is dominant when ≥ 80% of recognized media files are that type.
    /// Below this, the folder is Mixed and the user is prompted to choose.
    static let dominanceThreshold = 0.8

    /// Longest-edge pixel size for gallery thumbnails. `ThumbnailService` sizes its
    /// in-memory cache budget around this, so the two stay coupled through one value.
    static let galleryThumbnailPixelSize = 440

    /// Opacity of the accent-tinted selection highlight behind a selected row/cell,
    /// shared by every list/grid so the selection reads consistently across them.
    static let selectionHighlightOpacity = 0.22

    /// Classify a filename extension into a media type, or `nil` if unrecognized.
    static func mediaType(forExtension ext: String) -> MediaType? {
        let lower = ext.lowercased()
        if videoExtensions.contains(lower) { return .video }
        if imageExtensions.contains(lower) { return .image }
        if audioExtensions.contains(lower) { return .audio }
        return nil
    }
}
