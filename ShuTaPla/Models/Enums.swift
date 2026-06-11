//
//  Enums.swift
//  ShuTaPla
//
//  Shared enumerations used across the data model, services, and UI.
//  Declared `nonisolated` so they can be constructed and read from any
//  isolation context (the project defaults to `MainActor` isolation).
//

import Foundation

/// The kind of media a playlist and its files represent.
nonisolated enum MediaType: String, Codable, Sendable, CaseIterable {
    case video
    case image
    case audio
}

/// How an image is scaled to fit the player surface.
nonisolated enum ImageFitMode: String, Codable, Sendable, CaseIterable {
    case fit
    case cover
    case original
}

/// File-list presentation in Manager mode.
nonisolated enum ViewMode: String, Codable, Sendable {
    case list
    case gallery
}

/// Boolean combination applied to a multi-tag filter.
nonisolated enum FilterMode: String, Codable, Sendable {
    case and
    case or
}

/// Result of parsing the tag bracket in a filename.
nonisolated enum TaggingStatus: String, Codable, Sendable {
    case valid
    case untagged
    case invalid
}

/// Per-playlist persisted playback state.
nonisolated enum PlaybackState: String, Codable, Sendable {
    case stopped
    case playing
    case paused
}

/// Runtime-only iCloud availability of a file. Never persisted — derived
/// from disk on each scan/observation.
nonisolated enum CloudStatus: String, Sendable {
    case local
    case inCloud
    case downloading
}

/// Runtime-only Manager-mode filter that overrides the tag filter while active.
/// Mutually exclusive; never persisted.
nonisolated enum ServiceFilter: String, Sendable {
    case untagged
    case invalidTagging
    case skipped
}
