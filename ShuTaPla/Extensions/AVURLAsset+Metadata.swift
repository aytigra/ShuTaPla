//
//  AVURLAsset+Metadata.swift
//  ShuTaPla
//
//  Duration and display size read from an asset's moov atom — no frame is decoded. Shared by
//  the list-mode `MediaMetadataService` and the gallery thumbnailer, which each hold their own
//  asset (the thumbnailer's also drives frame generation) and read these off the main actor. The
//  thumbnailer additionally reads the colour tags (`videoColorTags`), the AVFoundation half of
//  the decode-time HDR fact; the list-mode extractor never touches HDR.
//

import AVFoundation

extension AVURLAsset {

    /// The asset's duration and — when `wantsVideo` — its video track's display size, read from the
    /// moov atom in one concurrent pass: the duration load runs alongside a single video-track load
    /// whose natural size and preferred transform are then read. No frame is decoded. Fields are
    /// `nil` when AVFoundation can't read them — the webm/mkv case, where the caller falls back to
    /// libmpv. `wantsVideo == false` (audio) reads only the duration, loading no track.
    nonisolated func videoMetadata(wantsVideo: Bool) async -> (duration: TimeInterval?, size: (width: Int, height: Int)?) {
        async let durationLoad = playableDuration()
        guard wantsVideo else { return (await durationLoad, nil) }

        async let trackLoad = try? loadTracks(withMediaType: .video).first
        let duration = await durationLoad
        guard let track = await trackLoad ?? nil else { return (duration, nil) }

        // Two sequential loads off the single track (`AVAssetTrack` is non-Sendable, so it can't
        // fan out to concurrent `async let` tasks). Natural size is loaded on its own so the display
        // dimensions survive even when the transform load fails — a track that reports a size
        // shouldn't lose it because a later property couldn't be read.
        guard let natural = try? await track.load(.naturalSize) else { return (duration, nil) }
        let transform = try? await track.load(.preferredTransform)

        // Display size: natural size with the preferred transform applied, so a rotated track
        // reports the shape it presents (matching mpv's `dwidth`/`dheight`). A failed transform
        // load defaults to `.identity`, leaving the unrotated natural size.
        let display = natural.applying(transform ?? .identity)
        let size = (width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()))
        return (duration, size)
    }

    /// The video track's colour transfer / primaries as mpv-style strings, read from its format
    /// description in the moov atom — no frame is decoded. The AVFoundation half of the thumbnailer's
    /// decode-time HDR detection (libmpv `video-params` is the other). `nil` when the asset carries no
    /// video track or none of the tags (SDR files routinely omit them, so an absent gamma reads SDR).
    nonisolated func videoColorTags() async -> (gamma: String?, primaries: String?) {
        guard let track = try? await loadTracks(withMediaType: .video).first ?? nil,
              let format = try? await track.load(.formatDescriptions).first
        else { return (nil, nil) }
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        return (VideoColorTags.mpvGamma(transfer), VideoColorTags.mpvPrimaries(primaries))
    }

    /// The asset's running time in seconds, or `nil` when it has no finite positive
    /// duration (an unbounded stream, or an asset AVFoundation can't read — the webm/mkv
    /// case, where the caller falls back to libmpv).
    private nonisolated func playableDuration() async -> TimeInterval? {
        let seconds = (try? await load(.duration)).map(CMTimeGetSeconds)
        return seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}
