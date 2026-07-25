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
    /// determined — and its HDR result, the frame's `video-params` colour tags routed
    /// to the sink (the libmpv half of the thumbnailer's decode-time HDR detection).
    /// Runs the blocking extraction off the cooperative thread pool so a slow or stuck
    /// decode never ties up a concurrency-limited Swift task thread.
    static func frame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, metadata: MediaMetadata, hdr: ThumbnailHDR?) {
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
    /// everything else. And the facts lag `FILE_LOADED` by an instant: `duration` and the
    /// demuxer dimensions land a few event-loop turns later (paused under `vo=null`, no frame
    /// decoded). mpv dispatches property-change *notifications* lazily, so instead of waiting
    /// for one the loop synchronously re-reads the missing facts on every wakeup and asks
    /// `probeSettled` whether it can return. A settle grace armed at `FILE_LOADED` bounds the
    /// wait: a file that never publishes a duration (a stream still being written) returns at
    /// the grace instead of stalling to the full deadline. `duration` is observed purely so its
    /// arrival wakes `mpv_wait_event` immediately rather than on the next timeout tick. HDR is
    /// not read here — the list probe never touches it; the gallery frame path does.
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
        var settleDeadline: Date?
        while Date() < deadline {
            if isCancelled() { break }
            guard let raw = mpv_wait_event(handle, 0.1) else { continue }
            switch raw.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = loadedMetadata(handle)
                settleDeadline = Date().addingTimeInterval(2)
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return loaded ?? MediaMetadata()
            default:
                break
            }
            if var metadata = loaded, let settleDeadline {
                refreshMissingFacts(&metadata, handle)
                loaded = metadata
                if probeSettled(metadata, graceElapsed: Date() >= settleDeadline) { return metadata }
            }
        }
        return loaded ?? MediaMetadata()
    }

    /// Whether the metadata probe has gathered all it usefully can and should return now. Settles
    /// once the duration is known (the demuxer dimensions land with or before it), and — so a file
    /// that never publishes a duration doesn't stall to the full deadline — once the settle grace
    /// since `FILE_LOADED` has elapsed.
    static func probeSettled(_ metadata: MediaMetadata, graceElapsed: Bool) -> Bool {
        metadata.duration != nil || graceElapsed
    }

    /// Synchronously re-reads any facts still missing from the live, loaded handle — the
    /// recovery for facts that lag `FILE_LOADED` (duration, dimensions).
    private static func refreshMissingFacts(_ metadata: inout MediaMetadata, _ handle: OpaquePointer) {
        metadata.duration = metadata.duration ?? knownDuration(handle)
        if metadata.width == nil, let dimensions = knownDimensions(handle) {
            metadata.width = dimensions.width
            metadata.height = dimensions.height
        }
    }

    /// The loaded file's duration and display dimensions, read at `FILE_LOADED` while the
    /// file is open — reading at `END_FILE` would be too late, as the properties revert as
    /// mpv unloads the file. File size is the caller's `stat`, so it's left `nil` here.
    private static func loadedMetadata(_ handle: OpaquePointer) -> MediaMetadata {
        let dimensions = knownDimensions(handle)
        return MediaMetadata(duration: knownDuration(handle), width: dimensions?.width, height: dimensions?.height)
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
    /// loaded instance knows and the frame's `video-params` colour tags as an HDR result.
    /// Synchronous and blocking — only called from `frame(at:maxPixelSize:)`.
    private static func extract(at url: URL, maxPixelSize: Int, isCancelled: () -> Bool) -> (image: CGImage?, metadata: MediaMetadata, hdr: ThumbnailHDR?) {
        guard !isCancelled(), let handle = mpv_create() else { return (nil, MediaMetadata(), nil) }
        defer { mpv_terminate_destroy(handle) }

        // mpv writes one PNG into a private directory we own and delete afterwards;
        // globbing it sidesteps guessing the image VO's serial filename.
        let outDir = FileManager.default.temporaryDirectory
            .appending(path: "mpv-thumb-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)) != nil
        else { return (nil, MediaMetadata(), nil) }
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

        guard mpv_initialize(handle) >= 0 else { return (nil, MediaMetadata(), nil) }
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        loadFile(handle, path: url.path)

        // Pump events until the frame is on disk and the duration is read — or, for a file
        // that never reports a duration, until a settle grace armed at `FILE_LOADED` elapses —
        // with a ceiling so a pathological decode can't block the pool thread indefinitely. The
        // paused instance keeps the file loaded the whole time, so any fact that lags
        // `FILE_LOADED` — duration, dimensions, and the `video-params` colour tags that only
        // settle once the frame is decoded — is synchronously re-read on every wakeup until it
        // arrives (mpv dispatches property-change notifications lazily, so waiting for
        // one is a race; the `duration` observation exists purely to wake
        // `mpv_wait_event` promptly). `MPV_EVENT_IDLE` is not terminal: mpv's core can
        // queue its startup idle event before the `loadfile` settles. Only a load that
        // really fails ends the paused file, so `END_FILE` returns whatever arrived. A
        // decode attempt on a PNG the VO is still writing returns `nil` and simply
        // retries on the next wakeup.
        var metadata = MediaMetadata()
        var gamma: String?
        var primaries: String?
        var settleDeadline: Date?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if isCancelled() { return (nil, metadata, videoHDR(metadata, gamma: gamma, primaries: primaries)) }
            guard let raw = mpv_wait_event(handle, 0.1) else { continue }
            switch raw.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                metadata = loadedMetadata(handle)
                settleDeadline = Date().addingTimeInterval(2)
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return (downscaledFrame(in: outDir, maxPixelSize: maxPixelSize), metadata,
                        videoHDR(metadata, gamma: gamma, primaries: primaries))
            default:
                break
            }
            if let settleDeadline {
                refreshMissingFacts(&metadata, handle)
                gamma = gamma ?? colorTag(handle, "video-params/gamma")
                primaries = primaries ?? colorTag(handle, "video-params/primaries")
                // Return the frame once it is written — as soon as the duration is known, or once
                // the settle grace has elapsed so a file that never reports one doesn't stall to
                // the deadline. No frame yet keeps waiting: the frame is the point of the extract.
                if let frame = downscaledFrame(in: outDir, maxPixelSize: maxPixelSize),
                   metadata.duration != nil || Date() >= settleDeadline {
                    return (frame, metadata, videoHDR(metadata, gamma: gamma, primaries: primaries))
                }
            }
        }
        // Deadline without a returnable frame: report whatever arrived.
        return (downscaledFrame(in: outDir, maxPixelSize: maxPixelSize), metadata,
                videoHDR(metadata, gamma: gamma, primaries: primaries))
    }

    /// The frame path's HDR result from the `video-params` colour tags the decode read, carried once
    /// the file opened as video (dimensions read). `nil` for an audio-only file or one that never
    /// loaded — the same "no video, no tag" case the metadata bundle marks with a `nil` `width`.
    private static func videoHDR(_ metadata: MediaMetadata, gamma: String?, primaries: String?) -> ThumbnailHDR? {
        metadata.width != nil ? .video(gamma: gamma, primaries: primaries) : nil
    }

    /// The PNG mpv wrote, downscaled to `maxPixelSize` through the shared image path — but only
    /// once it is fully written. A URL image source treats whatever bytes are on disk as the whole
    /// image, so a frame the `image` VO is mid-write decodes into a part-garbage raster that would
    /// then be cached; gating on the `IEND` trailer decodes only a complete file and returns nil
    /// otherwise, exactly as when no PNG exists yet — the pump loop retries until mpv finishes.
    static func downscaledFrame(in directory: URL, maxPixelSize: Int) -> CGImage? {
        guard let png = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension.lowercased() == "png" }),
            isCompletePNG(at: png)
        else { return nil }
        return ThumbnailService.imageThumbnail(at: png, maxPixelSize: maxPixelSize)
    }

    /// Whether the file ends with PNG's `IEND` chunk — the fixed 12-byte trailer every complete
    /// PNG carries and a mid-write file lacks. The image source's own completeness status can't be
    /// used: a URL source reports `.statusComplete` for a truncated file too, seeing its bytes as
    /// the entire image.
    static func isCompletePNG(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 12,
              (try? handle.seek(toOffset: size - 12)) != nil,
              let tail = try? handle.readToEnd()
        else { return false }
        return tail == Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
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
