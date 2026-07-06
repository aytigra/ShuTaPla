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

    /// Disk-cache size past which the app flags cache pressure — the Settings size readout turns
    /// orange and the Manager notice strip shows a banner. The thumbnail cache has no automatic
    /// eviction (it's ours to manage, not the OS Caches directory), so the caution nudges a manual
    /// clear before it grows without bound.
    static let thumbnailCacheWarningBytes = 1024 * 1024 * 1024   // 1 GB

    /// `UserDefaults` key for the cache-over-limit flag the playlist scan refreshes and the
    /// Manager banner reads via `@AppStorage`.
    static let thumbnailCacheOverLimitKey = "thumbnailCacheOverLimit"

    /// Whether a measured cache size warrants the caution — the one predicate the Settings readout
    /// and the notice-strip banner share. `false` while the size is still loading (`nil`) and at or
    /// below the threshold.
    static func cacheOverLimit(bytes: Int?) -> Bool {
        guard let bytes else { return false }
        return bytes > thumbnailCacheWarningBytes
    }

    /// Opacity of the accent-tinted selection highlight behind a selected row/cell,
    /// shared by every list/grid so the selection reads consistently across them.
    static let selectionHighlightOpacity = 0.22

    /// Height of the Player-mode top-edge hover zone that reveals the audio overlay. The
    /// Visual Overlay insets its top by this much so its close button sits clear of it.
    static let audioHoverZoneHeight: CGFloat = 60

    /// Classify a filename extension into a media type, or `nil` if unrecognized.
    static func mediaType(forExtension ext: String) -> MediaType? {
        let lower = ext.lowercased()
        if videoExtensions.contains(lower) { return .video }
        if imageExtensions.contains(lower) { return .image }
        if audioExtensions.contains(lower) { return .audio }
        return nil
    }
}
