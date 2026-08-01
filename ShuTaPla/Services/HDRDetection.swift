//
//  HDRDetection.swift
//  ShuTaPla
//
//  HDR as a decode-time fact, and the one sink that caches it. A file's HDR range is
//  determined only by decoding it for display — the gallery thumbnailer, the image engine,
//  the video engine — never by the header-level metadata read (which can't see it reliably).
//  Every decode producer routes its finding through `HDRCache`, so the persisted columns
//  (`isHDR`, `hdrGamma`, `hdrPrimaries`) hold only decode-determined values and the badge and
//  the pre-configured PQ layer can trust them without re-reading.
//
//  `VideoColorTags` is the pure CoreMedia/mpv → mpv-string map the video producers speak; it
//  lives here beside the sink because both are the HDR vocabulary of the app.
//

import Foundation
import CoreMedia
import Observation

@MainActor
@Observable
final class HDRCache {

    /// Records a still image's decode-determined HDR range on `file`. The gallery thumbnailer and
    /// the image engine each decode a `CGImage` and report its range here. Persists immediately so a
    /// later `includePendingChanges = false` object fetch can't refault the write away before autosave.
    /// A re-decode that settles the same fact writes nothing, so a re-display leaves the context clean
    /// and costs no save (`setIfChanged`).
    func record(imageIsHDR: Bool, for file: PlaylistFile) {
        file.setIfChanged(\.isHDR, to: imageIsHDR)
        file.trySave()
    }

    /// Records a video's decode-determined colour tags on `file`: the mpv-style gamma/primaries the
    /// layer pre-configures from, and the `isHDR` badge fact derived from the gamma. Called only from
    /// a decode surface (the thumbnailer's frame path, the video engine's live `video-params` pass),
    /// so a `nil` gamma is a genuine SDR reading — no PQ/HLG transfer — settling `isHDR` to a
    /// determined `false`, never a guess. Persists immediately for the same reason as the image sink.
    func record(gamma: String?, primaries: String?, for file: PlaylistFile) {
        file.setIfChanged(\.isHDR, to: VideoColorTags.isHDR(gamma: gamma))
        file.setIfChanged(\.hdrGamma, to: gamma)
        file.setIfChanged(\.hdrPrimaries, to: primaries)
        file.trySave()
    }

    /// Routes a thumbnail decode's HDR finding to the matching column writer — the gallery producer's
    /// entry, dispatched by media type so `GalleryCell` records whichever the decode determined.
    func record(_ finding: ThumbnailHDR, for file: PlaylistFile) {
        switch finding {
        case .image(let isHDR): record(imageIsHDR: isHDR, for: file)
        case .video(let gamma, let primaries): record(gamma: gamma, primaries: primaries, for: file)
        }
    }
}

/// The HDR fact a fresh thumbnail decode determined, carried out of the thumbnailer for `GalleryCell`
/// to route to `HDRCache`. `nil` (not this type) rides with a cache-served thumbnail — no decode ran,
/// so the record keeps whatever it already settled — and with an unreadable file.
nonisolated enum ThumbnailHDR: Sendable, Equatable {
    /// A still's decoded HDR range (`CGImage.isHDR`).
    case image(Bool)
    /// A video frame's colour tags (mpv-style gamma / primaries), from whichever backend decoded it.
    case video(gamma: String?, primaries: String?)
}

/// Maps a video's CoreMedia colour tags to the mpv-style strings the rest of the HDR path speaks
/// (`HDRVideoConfig.decide`, the persisted `hdrGamma`/`hdrPrimaries`). The AVFoundation format
/// description and libmpv both describe the same colour space; this normalises the AVFoundation
/// side onto mpv's vocabulary so a file read either way yields the same tags.
///
/// `nonisolated`: a pure mapping over strings, called from the `@concurrent` decode producers and
/// asserted against in a plain test suite, so it opts out of the project's main-actor default.
nonisolated enum VideoColorTags {

    // The CoreMedia colour constants are `CFString`; bridged to `String` once here so the switches
    // below match plain values (a bare `case constant as String:` reads as a cast pattern, not the
    // string comparison intended).
    private static let pqTransfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
    private static let hlgTransfer = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
    private static let sdrTransfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
    private static let rec2020Primaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
    private static let p3Primaries = kCMFormatDescriptionColorPrimaries_P3_D65 as String
    private static let rec709Primaries = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String

    /// The mpv-style transfer string (`pq`, `hlg`, `bt.709`) for a CoreMedia
    /// `TransferFunction` value, or `nil` when it's absent or one this path doesn't name.
    static func mpvGamma(_ transferFunction: String?) -> String? {
        switch transferFunction {
        case pqTransfer: return "pq"
        case hlgTransfer: return "hlg"
        case sdrTransfer: return "bt.709"
        default: return nil
        }
    }

    /// The mpv-style primaries string (`bt.2020`, `display-p3`, `bt.709`) for a CoreMedia
    /// `ColorPrimaries` value, or `nil` when it's absent or one this path doesn't name.
    static func mpvPrimaries(_ colorPrimaries: String?) -> String? {
        switch colorPrimaries {
        case rec2020Primaries: return "bt.2020"
        case p3Primaries: return "display-p3"
        case rec709Primaries: return "bt.709"
        default: return nil
        }
    }

    /// Whether a transfer function marks HDR content: PQ or HLG. The badge fact and the persisted
    /// `isHDR` derive from this. An absent or SDR gamma (`bt.709`, `nil`) is not HDR.
    static func isHDR(gamma: String?) -> Bool {
        gamma == "pq" || gamma == "hlg"
    }
}
