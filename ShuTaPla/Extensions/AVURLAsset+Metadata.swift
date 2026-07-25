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

    /// The asset's duration and — when `wantsVideo` — its video track's display size and
    /// mpv-style colour tags, read from the moov atom in one concurrent pass: the duration load
    /// runs alongside a single video-track load whose natural size, preferred transform, and
    /// format description are then read together. No frame is decoded. Fields are `nil` when
    /// AVFoundation can't read them — the webm/mkv case, where the caller falls back to libmpv.
    /// `wantsVideo == false` (audio) reads only the duration, loading no track.
    nonisolated func videoMetadata(wantsVideo: Bool) async -> (duration: TimeInterval?, size: (width: Int, height: Int)?, gamma: String?, primaries: String?) {
        async let durationLoad = playableDuration()
        guard wantsVideo else { return (await durationLoad, nil, nil, nil) }

        async let trackLoad = try? loadTracks(withMediaType: .video).first
        let duration = await durationLoad
        guard let track = await trackLoad ?? nil else { return (duration, nil, nil, nil) }

        // Two sequential loads off the single track (`AVAssetTrack` is non-Sendable, so it can't
        // fan out to concurrent `async let` tasks). Natural size is loaded on its own so the display
        // dimensions survive even when the transform / format-description load fails — a track that
        // reports a size shouldn't lose it because a later property couldn't be read.
        guard let natural = try? await track.load(.naturalSize) else { return (duration, nil, nil, nil) }
        let extras = try? await track.load(.preferredTransform, .formatDescriptions)

        // Display size: natural size with the preferred transform applied, so a rotated track
        // reports the shape it presents (matching mpv's `dwidth`/`dheight`). A failed transform
        // load defaults to `.identity`, leaving the unrotated natural size.
        let display = natural.applying(extras?.0 ?? .identity)
        let size = (width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()))

        // Colour tags from the format description; `nil` when the track carries none (SDR files
        // routinely omit them, so an absent gamma reads as SDR).
        let format = extras?.1.first
        let transfer = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String }
        let primaries = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String }
        return (duration, size, VideoColorTags.mpvGamma(transfer), VideoColorTags.mpvPrimaries(primaries))
    }

    /// The asset's running time in seconds, or `nil` when it has no finite positive
    /// duration (an unbounded stream, or an asset AVFoundation can't read — the webm/mkv
    /// case, where the caller falls back to libmpv).
    private nonisolated func playableDuration() async -> TimeInterval? {
        let seconds = (try? await load(.duration)).map(CMTimeGetSeconds)
        return seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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
