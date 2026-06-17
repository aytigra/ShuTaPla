//
//  MPVThumbnailer.swift
//  ShuTaPla
//
//  Frame extraction for video containers AVFoundation can't open (webm, mkv, …)
//  using libmpv. A short-lived, windowless mpv instance with the `image` video
//  output decodes a single representative frame and writes it to a temporary PNG,
//  which the caller downscales through the same image path as still images.
//
//  This is the cache-miss fallback behind `ThumbnailService.videoFrame`: it never
//  touches the playback engines' `MPVClient` or its render context — each call
//  owns a fresh handle for the lifetime of one extraction and tears it down.
//

import Foundation
import ImageIO
import Cmpv

// `nonisolated`: this project defaults to `@MainActor` isolation, but every member
// here runs off the main actor — the extraction blocks on a background Dispatch
// queue, and its `pool.async` closure must not be MainActor-isolated or it would
// trip an executor assertion when it runs on that background thread.
nonisolated enum MPVThumbnailer {

    /// One background-priority lane for all extractions. The serial queue produces
    /// a single thumbnail at a time, and each decode is itself single-threaded (see
    /// `vd-lavc-threads` below), so the work never claims more than one busy core and
    /// stays below user-initiated work — leaving the player's own decode the cores it
    /// needs when it starts. Misses are rare (results cache on disk), so serializing
    /// keeps the gallery fed without ever competing with playback.
    private static let pool = DispatchQueue(label: "com.aytigra.ShuTaPla.mpv-thumbnail", qos: .utility)

    /// A representative frame from the video at `url`, no larger than `maxPixelSize`
    /// on its longest edge (or `nil` when libmpv can't decode it), paired with the
    /// file's running time — which the same decode already determined, so the length
    /// indicator gets it for free rather than opening the file a second time. Runs
    /// the blocking extraction off the cooperative thread pool so a slow or stuck
    /// decode never ties up a concurrency-limited Swift task thread.
    static func frame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, duration: TimeInterval?) {
        await withCheckedContinuation { continuation in
            pool.async {
                continuation.resume(returning: extract(at: url, maxPixelSize: maxPixelSize))
            }
        }
    }

    /// The running time of the video at `url` in seconds, or `nil` when libmpv
    /// can't decode it. The cache-miss fallback behind `DurationService` for
    /// containers AVFoundation can't open. Runs the blocking probe off the shared
    /// pool so a stuck decode never ties up a concurrency-limited task thread.
    static func duration(at url: URL) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            pool.async {
                continuation.resume(returning: probeDuration(at: url))
            }
        }
    }

    /// Loads the file into a windowless, paused mpv instance just far enough to
    /// read the demuxer's `duration` property, decoding nothing. Synchronous and
    /// blocking — only called from `duration(at:)`.
    private static func probeDuration(at url: URL) -> TimeInterval? {
        guard let handle = mpv_create() else { return nil }
        defer { mpv_terminate_destroy(handle) }

        let options = [
            "config": "no",
            "load-scripts": "no",
            "terminal": "no",
            "audio": "no",
            "vo": "null",
            "pause": "yes",
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }

        guard mpv_initialize(handle) >= 0 else { return nil }
        loadFile(handle, path: url.path)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard let raw = mpv_wait_event(handle, 0.1) else { continue }
            switch raw.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                return knownDuration(handle)
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN, MPV_EVENT_IDLE:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// The loaded file's `duration` property in seconds, or `nil` when libmpv hasn't
    /// determined it (a container without a stored length, or one not yet loaded).
    private static func knownDuration(_ handle: OpaquePointer) -> TimeInterval? {
        var seconds: Double = 0
        guard mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &seconds) >= 0,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// Drives a one-shot mpv instance to write a single frame, then downscales it,
    /// also reporting the file's duration the loaded instance knows. Synchronous and
    /// blocking — only called from `frame(at:maxPixelSize:)`.
    private static func extract(at url: URL, maxPixelSize: Int) -> (image: CGImage?, duration: TimeInterval?) {
        guard let handle = mpv_create() else { return (nil, nil) }
        defer { mpv_terminate_destroy(handle) }

        // mpv writes one PNG into a private directory we own and delete afterwards;
        // globbing it sidesteps guessing the image VO's serial filename.
        let outDir = FileManager.default.temporaryDirectory
            .appending(path: "mpv-thumb-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)) != nil
        else { return (nil, nil) }
        defer { try? FileManager.default.removeItem(at: outDir) }

        // Ignore the user's mpv config and scripts; decode one frame, 10% in (past
        // the often-black opening), into a PNG with no window or audio.
        let options = [
            "config": "no",
            "load-scripts": "no",
            "terminal": "no",
            "audio": "no",
            "hwdec": "no",
            // Decode on a single thread: one frame doesn't need many, and capping it
            // keeps the extraction to one core so it can't starve the player's decode.
            "vd-lavc-threads": "1",
            "vo": "image",
            "vo-image-format": "png",
            "vo-image-outdir": outDir.path,
            "start": "10%",
            "frames": "1",
            "hr-seek": "yes",
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }

        guard mpv_initialize(handle) >= 0 else { return (nil, nil) }
        loadFile(handle, path: url.path)

        // Pump events until the single frame ends the file, with a ceiling so a
        // pathological decode can't block the pool thread indefinitely. The file is
        // its duration comes along for free — captured at `FILE_LOADED`, while the
        // file is open, so the length indicator needn't reopen it. Reading at
        // `END_FILE` would be too late: the property reverts as mpv unloads the file.
        var duration: TimeInterval?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard let raw = mpv_wait_event(handle, 0.1) else { continue }
            switch raw.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                duration = knownDuration(handle)
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN, MPV_EVENT_IDLE:
                return (downscaledFrame(in: outDir, maxPixelSize: maxPixelSize), duration)
            default:
                continue
            }
        }
        return (downscaledFrame(in: outDir, maxPixelSize: maxPixelSize), duration)
    }

    /// The PNG mpv wrote, downscaled to `maxPixelSize` through the shared image path.
    private static func downscaledFrame(in directory: URL, maxPixelSize: Int) -> CGImage? {
        guard let png = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension.lowercased() == "png" })
        else { return nil }
        return ThumbnailService.imageThumbnail(at: png, maxPixelSize: maxPixelSize)
    }

    /// Issues `loadfile <path>` against the handle, building the NULL-terminated
    /// `argv` libmpv expects.
    private static func loadFile(_ handle: OpaquePointer, path: String) {
        "loadfile".withCString { command in
            path.withCString { file in
                var argv: [UnsafePointer<CChar>?] = [command, file, nil]
                argv.withUnsafeMutableBufferPointer { buffer in
                    _ = mpv_command(handle, buffer.baseAddress)
                }
            }
        }
    }
}
