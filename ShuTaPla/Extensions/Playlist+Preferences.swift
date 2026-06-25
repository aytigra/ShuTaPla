//
//  Playlist+Preferences.swift
//  ShuTaPla
//
//  Resolves a playlist's effective preferences: each per-playlist override falls back to the
//  corresponding global default when unset (`nil`). One place for the fallback rule so the
//  coordinator, the players, and the settings UI all agree on what a playlist's settings are.
//

import Foundation

extension Playlist {
    /// Seconds between slideshow advances: the playlist's own interval, or the global default.
    func effectiveSlideshowInterval(_ settings: GlobalSettings) -> TimeInterval {
        preferences.slideshowInterval ?? settings.defaultSlideshowInterval
    }

    /// How an image is scaled to the surface: the playlist's own fit mode, or the global default.
    func effectiveImageFitMode(_ settings: GlobalSettings) -> ImageFitMode {
        preferences.imageFitMode ?? settings.defaultImageFitMode
    }

    /// Whether playback resumes mid-file: the playlist's own choice, or the global default.
    func effectiveFilePositionPersistence(_ settings: GlobalSettings) -> Bool {
        preferences.filePositionPersistence ?? settings.defaultFilePositionPersistence
    }
}
