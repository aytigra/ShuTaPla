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
import Synchronization
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
    /// file's metadata — duration and pixel dimensions the same decode already
    /// determined, so the gallery's badge and cached shape get them for free rather
    /// than opening the file a second time. Runs the blocking extraction off the
    /// cooperative thread pool so a slow or stuck decode never ties up a
    /// concurrency-limited Swift task thread.
    static func frame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, metadata: MediaMetadata) {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pool.async {
                    continuation.resume(returning: extract(
                        at: url, maxPixelSize: maxPixelSize, isCancelled: { cancelled.withLock { $0 } }
                    ))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// The metadata of the video at `url` — duration and pixel dimensions — or an empty
    /// bundle when libmpv can't decode it. The cache-miss fallback behind
    /// `MediaMetadataService` for containers AVFoundation can't open. Runs the blocking
    /// probe off the shared pool so a stuck decode never ties up a concurrency-limited
    /// task thread.
    static func metadata(at url: URL) async -> MediaMetadata {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pool.async {
                    continuation.resume(returning: probeMetadata(at: url, isCancelled: { cancelled.withLock { $0 } }))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Loads the file into a windowless, paused mpv instance just far enough to read the
    /// demuxer's `duration` and display dimensions, decoding nothing. Synchronous and
    /// blocking — only called from `metadata(at:)`.
    ///
    /// Two races are handled while pumping events. mpv's core can queue its startup idle
    /// event before the `loadfile` settles, so `MPV_EVENT_IDLE` must not be treated as
    /// terminal — a load that really fails ends with `END_FILE`, and the deadline caps
    /// everything else. And `duration` (occasionally the dimensions too) can lag
    /// `FILE_LOADED` by an instant — and mpv dispatches property-change *notifications*
    /// lazily, so instead of waiting for one the loop synchronously re-reads the missing
    /// facts on every wakeup until the duration arrives (or the file ends / the deadline
    /// passes, which return whatever was captured). `duration` is observed purely so its
    /// arrival wakes `mpv_wait_event` immediately rather than on the next timeout tick.
    private static func probeMetadata(at url: URL, isCancelled: () -> Bool) -> MediaMetadata {
        guard !isCancelled(), let handle = mpv_create() else { return MediaMetadata() }
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

        guard mpv_initialize(handle) >= 0 else { return MediaMetadata() }
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        loadFile(handle, path: url.path)

        var loaded: MediaMetadata?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if isCancelled() { break }
            guard let raw = mpv_wait_event(handle, 0.1) else { continue }
            switch raw.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = loadedMetadata(handle)
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return loaded ?? MediaMetadata()
            default:
                break
            }
            if var metadata = loaded {
                refreshMissingFacts(&metadata, handle)
                loaded = metadata
                if metadata.duration != nil { return metadata }
            }
        }
        return loaded ?? MediaMetadata()
    }

    /// Synchronously re-reads any facts still missing from the live, loaded handle — the
    /// recovery for facts that lag `FILE_LOADED` (duration, dimensions) or only settle
    /// once a frame is decoded (the colour tags, under `vo=image`).
    private static func refreshMissingFacts(_ metadata: inout MediaMetadata, _ handle: OpaquePointer) {
        metadata.duration = metadata.duration ?? knownDuration(handle)
        if metadata.width == nil, let dimensions = knownDimensions(handle) {
            metadata.width = dimensions.width
            metadata.height = dimensions.height
        }
        metadata.hdrGamma = metadata.hdrGamma ?? colorTag(handle, "video-params/gamma")
        metadata.hdrPrimaries = metadata.hdrPrimaries ?? colorTag(handle, "video-params/primaries")
    }

    /// The loaded file's duration and display dimensions, read at `FILE_LOADED` while the
    /// file is open — reading at `END_FILE` would be too late, as the properties revert as
    /// mpv unloads the file. File size is the caller's `stat`, so it's left `nil` here. The
    /// colour tags read here too, best-effort: `video-params` is populated once decode is up,
    /// which may lag `FILE_LOADED`, so `refreshMissingFacts` re-reads them on later wakeups.
    private static func loadedMetadata(_ handle: OpaquePointer) -> MediaMetadata {
        let dimensions = knownDimensions(handle)
        return MediaMetadata(duration: knownDuration(handle), width: dimensions?.width, height: dimensions?.height,
                             hdrGamma: colorTag(handle, "video-params/gamma"),
                             hdrPrimaries: colorTag(handle, "video-params/primaries"))
    }

    /// An mpv `video-params/*` colour string, or `nil` when the property is unavailable or empty
    /// (no frame decoded yet, or a value mpv reports as absent). The demuxer/decoder already speaks
    /// mpv's vocabulary (`pq`/`hlg`, `bt.2020`/`display-p3`), so the value is used as-is.
    private static func colorTag(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// The loaded file's `duration` property in seconds, or `nil` when libmpv hasn't
    /// determined it (a container without a stored length, or one not yet loaded).
    private static func knownDuration(_ handle: OpaquePointer) -> TimeInterval? {
        var seconds: Double = 0
        guard mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &seconds) >= 0,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// The loaded file's video dimensions, or `nil` when libmpv hasn't determined them
    /// (an audio-only file, or one not yet loaded). Reads the demuxer's track dimensions,
    /// which are known at `FILE_LOADED` without decoding a frame — `dwidth`/`dheight` are
    /// the display size and stay `0` under `vo=null` until a frame is decoded.
    private static func knownDimensions(_ handle: OpaquePointer) -> (width: Int, height: Int)? {
        guard let width = intProperty(handle, "current-tracks/video/demux-w"),
              let height = intProperty(handle, "current-tracks/video/demux-h"),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// An integer mpv property, or `nil` when it isn't available.
    private static func intProperty(_ handle: OpaquePointer, _ name: String) -> Int? {
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return Int(value)
    }

    /// Drives a windowless mpv instance, paused on a representative frame that the
    /// `image` VO writes to disk, then downscales it — also reporting the metadata the
    /// loaded instance knows. Synchronous and blocking — only called from
    /// `frame(at:maxPixelSize:)`.
    private static func extract(at url: URL, maxPixelSize: Int, isCancelled: () -> Bool) -> (image: CGImage?, metadata: MediaMetadata) {
        guard !isCancelled(), let handle = mpv_create() else { return (nil, MediaMetadata()) }
        defer { mpv_terminate_destroy(handle) }

        // mpv writes one PNG into a private directory we own and delete afterwards;
        // globbing it sidesteps guessing the image VO's serial filename.
        let outDir = FileManager.default.temporaryDirectory
            .appending(path: "mpv-thumb-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)) != nil
        else { return (nil, MediaMetadata()) }
        defer { try? FileManager.default.removeItem(at: outDir) }

        // Ignore the user's mpv config and scripts; pause on the frame 10% in (past the
        // often-black opening), which the image VO writes as a PNG — no window, no audio.
        // Pausing (rather than playing one frame to its natural end) keeps the file
        // loaded while the loop below reads its properties.
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
            "pause": "yes",
            "hr-seek": "yes",
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }

        guard mpv_initialize(handle) >= 0 else { return (nil, MediaMetadata()) }
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        loadFile(handle, path: url.path)

        // Pump events until the frame is on disk and the duration is read, with a ceiling
        // so a pathological decode can't block the pool thread indefinitely. The paused
        // instance keeps the file loaded the whole time, so any fact that lags
        // `FILE_LOADED` — duration, dimensions, and the colour tags that only settle once
        // the frame is decoded — is synchronously re-read on every wakeup until it
        // arrives (mpv dispatches property-change notifications lazily, so waiting for
        // one is a race; the `duration` observation exists purely to wake
        // `mpv_wait_event` promptly). `MPV_EVENT_IDLE` is not terminal: mpv's core can
        // queue its startup idle event before the `loadfile` settles. Only a load that
        // really fails ends the paused file, so `END_FILE` returns whatever arrived. A
        // decode attempt on a PNG the VO is still writing returns `nil` and simply
        // retries on the next wakeup.
        var metadata = MediaMetadata()
        var isLoaded = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if isCancelled() { return (nil, metadata) }
            guard let raw = mpv_wait_event(handle, 0.1) else { continue }
            switch raw.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                metadata = loadedMetadata(handle)
                isLoaded = true
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return (downscaledFrame(in: outDir, maxPixelSize: maxPixelSize), metadata)
            default:
                break
            }
            if isLoaded {
                refreshMissingFacts(&metadata, handle)
                if metadata.duration != nil,
                   let frame = downscaledFrame(in: outDir, maxPixelSize: maxPixelSize) {
                    return (frame, metadata)
                }
            }
        }
        // Deadline without both the frame and a duration: report whatever arrived.
        return (downscaledFrame(in: outDir, maxPixelSize: maxPixelSize), metadata)
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
