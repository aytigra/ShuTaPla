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

    /// Capitalized human-facing name (the media-type choice prompt, labels).
    var displayName: String {
        switch self {
        case .video: return "Video"
        case .image: return "Image"
        case .audio: return "Audio"
        }
    }

    /// SF Symbol standing for a stack of this type's files (the empty-library placeholders).
    var systemImage: String {
        switch self {
        case .video: return "film.stack"
        case .image: return "photo.stack"
        case .audio: return "music.note.list"
        }
    }

    /// Lowercase plural naming this type's files inside a sentence ("Add a folder of …").
    var pluralNoun: String {
        switch self {
        case .video: return "videos"
        case .image: return "images"
        case .audio: return "audio files"
        }
    }
}

/// How an image is scaled to fit the player surface.
nonisolated enum ImageFitMode: String, Codable, Sendable, CaseIterable {
    case fit
    case cover
    case original

    /// Capitalized human-facing name (the settings pickers).
    var displayName: String {
        switch self {
        case .fit: return "Fit"
        case .cover: return "Cover"
        case .original: return "Original"
        }
    }

    /// The next mode in the `[shift]` fit-mode cycle: Fit → Cover → Original → Fit.
    var next: ImageFitMode {
        switch self {
        case .fit: return .cover
        case .cover: return .original
        case .original: return .fit
        }
    }

    /// The frame the player gives the image layer before pan/zoom is applied. `.fit`/`.cover`
    /// frame the surface and let the layer's gravity do the scaling; `.original` frames the
    /// picture pixel-perfectly — pixels over the display scale, one image pixel per device
    /// pixel, exactly the size `.center` gravity renders — so the frame hugs the picture and
    /// pan/zoom can roam a picture larger than the surface without empty margins.
    func baseSize(imagePixelSize: CGSize, surface: CGSize, displayScale: CGFloat) -> CGSize {
        self == .original
            ? CGSize(width: imagePixelSize.width / displayScale,
                     height: imagePixelSize.height / displayScale)
            : surface
    }
}

/// File-list presentation in Manager mode.
nonisolated enum ViewMode: String, Codable, Sendable {
    case list
    case gallery
}

/// Result of parsing the tag bracket in a filename.
nonisolated enum TaggingStatus: String, Codable, Sendable {
    case valid
    case untagged
    case invalid

    /// Stable integer discriminator stored on `PlaylistFile` so triage filters can be
    /// expressed as a `#Predicate` — which can compare a scalar column but not capture the
    /// enum itself ("Captured/constant values of type 'TaggingStatus' are not supported").
    var code: Int {
        switch self {
        case .valid: return 0
        case .untagged: return 1
        case .invalid: return 2
        }
    }

    init(code: Int) {
        switch code {
        case 0: self = .valid
        case 2: self = .invalid
        default: self = .untagged
        }
    }
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

/// A triage filter that overrides the tag filter while set. Mutually exclusive,
/// and persisted on the playlist's `serviceFilterRaw` so triage resumes across launches.
nonisolated enum ServiceFilter: String, Codable, Sendable {
    case untagged
    case invalidTagging

    /// SF Symbol shown in the filter banner and the center-panel counter notices.
    var systemImage: String {
        switch self {
        case .untagged: return "tag.slash"
        case .invalidTagging: return "exclamationmark.triangle"
        }
    }

    /// Descriptive label for the "Showing …" active-filter banner.
    var label: String {
        switch self {
        case .untagged: return "untagged files"
        case .invalidTagging: return "files with invalid tagging"
        }
    }
}
