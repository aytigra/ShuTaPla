//
//  AVURLAsset+Metadata.swift
//  ShuTaPla
//
//  Duration and display size read from an asset's moov atom — no frame is decoded.
//  Shared by the list-mode `MediaMetadataService` and the gallery thumbnailer, which
//  each hold their own asset (the thumbnailer's also drives frame generation) and read
//  these off the main actor.
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
}
