//
//  DurationService.swift
//  ShuTaPla
//
//  Running-time extraction for the Manager's video length indicators. The first
//  time a video file's length is needed, it is read off the main actor — via
//  AVFoundation, falling back to libmpv for containers AVFoundation can't open
//  (webm, mkv, …) — then cached on the model (`PlaylistFile.duration`) so the
//  value is instant on every later display and across launches.
//
//  The public entry point reads the model on the main actor, hands Sendable
//  values (bookmark, relative path) to a `nonisolated` worker, and writes the
//  result back onto the model when it returns.
//

import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class DurationService {

    /// The running time of `file`, read and cached on first request. Returns the
    /// value stored on the model when already known, otherwise extracts it off the
    /// main actor and persists it. `nil` when the length can't be determined.
    func duration(for file: PlaylistFile, in playlist: Playlist) async -> TimeInterval? {
        if let cached = file.duration { return cached }

        let seconds = await Self.extract(
            bookmark: playlist.folderBookmark,
            relativePath: file.relativePath
        )
        guard let seconds else { return nil }
        file.duration = seconds
        return seconds
    }

    /// Resolves the file and reads its duration, AVFoundation first then libmpv.
    /// Returns `nil` when the file is gone or neither decoder reports a positive
    /// length.
    ///
    /// `@concurrent` so the resolve + decode lands on the cooperative pool: under
    /// MainActor-default isolation a plain `nonisolated async` would run on the
    /// caller's actor (the main actor for `duration(for:in:)`), freezing the UI while
    /// the file list populates uncached lengths.
    @concurrent nonisolated static func extract(bookmark: Data, relativePath: String) async -> TimeInterval? {
        (try? await BookmarkService.withResolvedFile(bookmark: bookmark, relativePath: relativePath) { fileURL in
            if let seconds = await avDuration(at: fileURL) { return seconds }
            return await MPVThumbnailer.duration(at: fileURL)
        }) ?? nil
    }

    @concurrent private nonisolated static func avDuration(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
