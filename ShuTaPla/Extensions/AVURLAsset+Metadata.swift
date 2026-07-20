//
//  AVURLAsset+Metadata.swift
//  ShuTaPla
//
//  Duration, display size, and colour tags read from an asset's moov atom — no frame is
//  decoded. Shared by the list-mode `MediaMetadataService` and the gallery thumbnailer,
//  which each hold their own asset (the thumbnailer's also drives frame generation) and
//  read these off the main actor.
//

import AVFoundation

extension AVURLAsset {

    /// The asset's running time in seconds, or `nil` when it has no finite positive
    /// duration (an unbounded stream, or an asset AVFoundation can't read — the webm/mkv
    /// case, where the caller falls back to libmpv).
    nonisolated func playableDuration() async -> TimeInterval? {
        let seconds = (try? await load(.duration)).map(CMTimeGetSeconds)
        return seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The video track's display size in pixels — natural size with the preferred transform
    /// applied, so a rotated track reports the shape it presents (matching mpv's `dwidth`/
    /// `dheight`). `nil` when there is no video track or AVFoundation can't read it.
    nonisolated func displayPixelSize() async -> (width: Int, height: Int)? {
        guard let track = try? await loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let display = size.applying(transform)
        return (Int(abs(display.width).rounded()), Int(abs(display.height).rounded()))
    }

    /// The video track's colour transfer and primaries as mpv-style strings, read from the
    /// format description (moov atom) — no frame is decoded. `nil` fields when the track
    /// carries no colour tags (SDR files routinely omit them, so an absent gamma reads as
    /// SDR) or AVFoundation can't open the container (the webm/mkv case, where the caller
    /// falls back to libmpv's `video-params`).
    nonisolated func hdrColorTags() async -> (gamma: String?, primaries: String?) {
        guard let track = try? await loadTracks(withMediaType: .video).first,
              let format = (try? await track.load(.formatDescriptions))?.first else { return (nil, nil) }
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        return (VideoColorTags.mpvGamma(transfer as? String), VideoColorTags.mpvPrimaries(primaries as? String))
    }
}

/// Maps a video's CoreMedia colour tags to the mpv-style strings the rest of the HDR path speaks
/// (`HDRVideoConfig.decide`, the persisted `hdrGamma`/`hdrPrimaries`). The AVFoundation format
/// description and libmpv both describe the same colour space; this normalises the AVFoundation
/// side onto mpv's vocabulary so a file read either way yields the same tags.
///
/// `nonisolated`: a pure mapping over strings, called from the `@concurrent` extractors and
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
