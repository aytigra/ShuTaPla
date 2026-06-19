//
//  ThumbnailService.swift
//  ShuTaPla
//
//  Async thumbnail generation for the gallery view. Images are thumbnailed with
//  `CGImageSource`; videos with `AVAssetImageGenerator`. Results are cached in
//  memory (`NSCache`) and on disk (Caches directory). The cache key is the file's
//  relative path + on-disk modification date + requested size, so an edited file
//  invalidates its stale thumbnail automatically.
//
//  Generation runs off the main actor: the public entry point reads the model on
//  the main actor, then hands Sendable values (bookmark, relative path, size) to
//  `nonisolated` workers that resolve the bookmark, read the file, and return HEIC
//  `Data` that the main actor turns back into an `NSImage`.
//
//  The in-memory cache is bounded by the decoded byte size of its images, so
//  scrolling a large playlist evicts the least-recently-used thumbnails once the
//  budget is reached rather than retaining every decoded bitmap. Reloading an
//  evicted thumbnail is a cheap disk decode.
//

import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Observation

@MainActor
@Observable
final class ThumbnailService {

    /// Decoded thumbnails, keyed by cache key. Spares re-reads while scrolling.
    /// Bounded by `cacheByteBudget` of decoded pixels; over budget, the cache
    /// evicts least-recently-used entries.
    @ObservationIgnored private let memory = NSCache<NSString, NSImage>()

    /// Decoded-pixel ceiling for `memory`. An `AppConstants.galleryThumbnailPixelSize`
    /// (440 px) thumbnail decodes to ~0.6 MB, so 128 MB holds ~200 of them — comfortably more than any viewport plus its
    /// scroll buffer, while capping the footprint of a large playlist.
    private static let cacheByteBudget = 128 * 1024 * 1024

    /// Where generated thumbnails are persisted between launches.
    @ObservationIgnored private let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        memory.totalCostLimit = Self.cacheByteBudget
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let base = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "ShuTaPla"
            self.cacheDirectory = base
                .appending(path: bundleID, directoryHint: .isDirectory)
                .appending(path: "Thumbnails", directoryHint: .isDirectory)
        }
    }

    // MARK: - Public API

    /// A thumbnail for `file`, generated on first request and cached thereafter,
    /// paired with the video's running time when generation determined it. The image
    /// is `nil` when the file can't be read or decoded (the caller shows a
    /// placeholder); the duration is `nil` for images, and for a thumbnail served
    /// from the on-disk cache (no decode ran to read it — the caller falls back to
    /// the length persisted on the model). `maxPixelSize` is the longest edge in
    /// pixels.
    func thumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) async -> (image: NSImage?, duration: TimeInterval?) {
        let bookmark = playlist.folderBookmark
        let relativePath = file.relativePath
        let isVideo = playlist.mediaType == .video
        let memKey = memoryKey(for: file, in: playlist, maxPixelSize: maxPixelSize)

        if let cached = memory.object(forKey: memKey) { return (cached, nil) }

        // Generation *and* decode happen off the main actor, so the cell receives a
        // ready-to-draw image and scrolling never blocks on a lazy draw-time decode.
        let produced = await Self.produceImage(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            cacheDirectory: cacheDirectory
        )
        guard let boxed = produced.image else { return (nil, nil) }

        memory.setObject(boxed.image, forKey: memKey, cost: Self.byteCost(of: boxed.image))
        return (boxed.image, produced.duration)
    }

    /// Decoded byte size of an image, used as its cache cost: pixel area × 4 (RGBA).
    /// The image is built from a `CGImage`, so its first representation carries the
    /// true pixel dimensions.
    private static func byteCost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }

    /// A synchronous in-memory hit for the scroll-hot path — no disk I/O, so a
    /// cell that has been shown before paints its thumbnail immediately without a
    /// placeholder flash. Returns `nil` on a miss; the caller then awaits
    /// `thumbnail(for:in:maxPixelSize:)` to generate it off the main actor.
    func cachedThumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) -> NSImage? {
        memory.object(forKey: memoryKey(for: file, in: playlist, maxPixelSize: maxPixelSize))
    }

    /// Cheap, disk-I/O-free key for the in-memory cache: playlist id + relative path +
    /// size. The playlist's stable id is collision-free (unlike a per-process
    /// `hashValue`, which two folders' bookmarks can share and cross-paint). The on-disk
    /// cache keys additionally by modification date; an in-memory entry is refreshed when
    /// the file is renamed (its relative path changes) or on the next launch.
    private func memoryKey(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) -> NSString {
        "\(playlist.id.uuidString)|\(file.relativePath)|\(maxPixelSize)" as NSString
    }

    /// Disk-cached thumbnail bytes for a file addressed by bookmark + relative
    /// path, without the in-memory `NSImage` layer. Used by the gallery's higher
    /// level path and exercised directly by tests.
    func thumbnailData(bookmark: Data, relativePath: String, isVideo: Bool, maxPixelSize: Int) async -> Data? {
        await Self.produceData(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            cacheDirectory: cacheDirectory
        ).data
    }

    // MARK: - Cache key

    /// `<relativePath>|<modDate>|<size>` hashed to a filesystem-safe name. A
    /// changed modification date yields a new key, invalidating the old thumbnail.
    /// Returns `nil` when the file is gone. The produce path computes the key inline
    /// (`cacheKeyComponents`) to resolve the bookmark only once; this entry point is
    /// exercised directly by tests.
    @concurrent
    nonisolated static func cacheKey(bookmark: Data, relativePath: String, maxPixelSize: Int) async -> String? {
        try? await BookmarkService.withResolvedFile(bookmark: bookmark, relativePath: relativePath) { fileURL in
            cacheKeyComponents(fileURL: fileURL, relativePath: relativePath, maxPixelSize: maxPixelSize)
        }
    }

    /// The disk-cache key from an already-resolved file URL: relative path, on-disk
    /// modification date, and size, hashed to a filesystem-safe name.
    private nonisolated static func cacheKeyComponents(fileURL: URL, relativePath: String, maxPixelSize: Int) -> String {
        let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let stamp = modDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "0"
        return digest("\(relativePath)|\(stamp)|\(maxPixelSize)")
    }

    /// Whether `data` decodes as a complete image, used to reject a 0-byte or truncated
    /// disk-cache file before treating it as a hit. `statusComplete` distinguishes a
    /// fully written thumbnail from a partial one without forcing a full raster decode.
    private nonisolated static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return false }
        return true
    }

    private nonisolated static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Disk cache + generation

    /// Returns the on-disk thumbnail if present; otherwise generates one, writes it
    /// to the cache, and returns it. The disk-hit path skips generation, so it
    /// reports no duration — a fresh generation reports the length its decode
    /// determined (videos only), which the caller persists.
    private nonisolated static func produceData(
        bookmark: Data,
        relativePath: String,
        isVideo: Bool,
        maxPixelSize: Int,
        cacheDirectory: URL
    ) async -> (data: Data?, duration: TimeInterval?) {
        // One resolve + scoped-access session for the whole produce: derive the key
        // (which needs the on-disk modification date), check the disk cache, and render
        // on a miss — rather than resolving once to key and again to render.
        let produced = try? await BookmarkService.withResolvedFile(
            bookmark: bookmark, relativePath: relativePath
        ) { fileURL -> (data: Data?, duration: TimeInterval?) in
            let key = cacheKeyComponents(fileURL: fileURL, relativePath: relativePath, maxPixelSize: maxPixelSize)
            let diskURL = cacheDirectory.appending(path: "\(key).heic")
            if let data = try? Data(contentsOf: diskURL) {
                if isDecodableImage(data) { return (data, nil) }
                // A 0-byte or truncated cache file (an interrupted prior write) reads fine
                // but can't be decoded into a thumbnail — without this it would "hit"
                // forever and leave the cell stuck on a placeholder. Drop it and regenerate.
                try? FileManager.default.removeItem(at: diskURL)
            }

            let rendered = await renderThumbnail(at: fileURL, isVideo: isVideo, maxPixelSize: maxPixelSize)
            guard let data = rendered.data else { return (nil, nil) }
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: diskURL)
            return (data, rendered.duration)
        }
        return produced ?? (nil, nil)
    }

    /// Like `produceData`, but additionally decodes the encoded bytes into a fully
    /// rasterized `NSImage` off the main actor. Wrapping the result lets it cross
    /// back to the main actor without a draw-time decode on the scroll path. Carries
    /// the duration `produceData` reported through unchanged.
    @concurrent
    private nonisolated static func produceImage(
        bookmark: Data,
        relativePath: String,
        isVideo: Bool,
        maxPixelSize: Int,
        cacheDirectory: URL
    ) async -> (image: SendableImage?, duration: TimeInterval?) {
        let produced = await produceData(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            cacheDirectory: cacheDirectory
        )
        guard let data = produced.data else { return (nil, nil) }

        // `cgImage` forces the decode here, off-main; `NSImage(cgImage:)` then wraps
        // an already-decoded bitmap so no lazy decode happens when the cell draws.
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return (nil, nil) }
        return (SendableImage(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))), produced.duration)
    }

    // MARK: - Generation

    /// Renders a thumbnail for a file on disk and encodes it as HEIC, reporting the
    /// running time alongside it for videos (a frame decode determines it anyway).
    /// Used by `produceData` and exercised directly by tests. `@concurrent` so the
    /// CPU-bound encode is guaranteed off the main actor even for a caller already on it,
    /// rather than relying on the one entry point that happens to hop.
    @concurrent
    nonisolated static func renderThumbnail(at fileURL: URL, isVideo: Bool, maxPixelSize: Int) async -> (data: Data?, duration: TimeInterval?) {
        if isVideo {
            let frame = await videoFrame(at: fileURL, maxPixelSize: maxPixelSize)
            guard let cgImage = frame.image else { return (nil, nil) }
            return (encodeHEIC(cgImage), frame.duration)
        }
        guard let cgImage = imageThumbnail(at: fileURL, maxPixelSize: maxPixelSize) else { return (nil, nil) }
        return (encodeHEIC(cgImage), nil)
    }

    /// Encodes a thumbnail as HEIC. HEVC intra-frame compression is several times
    /// smaller than PNG for photographic content and is hardware-accelerated on
    /// Apple silicon; it is lossy at `quality`. An alpha channel is kept only when
    /// the image actually uses transparency, so an opaque source neither inflates
    /// the file nor doubles its decoded footprint with a redundant channel.
    private nonisolated static func encodeHEIC(_ cgImage: CGImage, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, flattenedIfOpaque(cgImage), [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Returns an alpha-free copy when `cgImage` carries an alpha channel whose
    /// pixels are all fully opaque; otherwise returns it unchanged. Redrawing into
    /// an opaque context drops the redundant channel that ImageIO warns about,
    /// while genuinely transparent thumbnails keep their alpha.
    private nonisolated static func flattenedIfOpaque(_ cgImage: CGImage) -> CGImage {
        switch cgImage.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            return cgImage          // no alpha channel to drop
        default:
            break
        }
        guard isFullyOpaque(cgImage),
              let context = CGContext(
                  data: nil,
                  width: cgImage.width,
                  height: cgImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return cgImage }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return context.makeImage() ?? cgImage
    }

    /// Whether every pixel of a 32-bit RGBA/BGRA image is fully opaque. Reads the
    /// alpha byte of each pixel; returns `false` for layouts it can't inspect, so
    /// the caller leaves the image untouched.
    private nonisolated static func isFullyOpaque(_ cgImage: CGImage) -> Bool {
        guard cgImage.bitsPerPixel == 32,
              let data = cgImage.dataProvider?.data else { return false }
        let length = CFDataGetLength(data)
        guard let bytes = CFDataGetBytePtr(data) else { return false }
        let alphaFirst = cgImage.alphaInfo == .premultipliedFirst || cgImage.alphaInfo == .first
        var offset = alphaFirst ? 0 : 3
        while offset < length {
            if bytes[offset] != 0xFF { return false }
            offset += 4
        }
        return true
    }

    /// Downscales a still image (or a frame mpv has already written to disk) to
    /// `maxPixelSize` on its longest edge. Shared with `MPVThumbnailer`, which
    /// extracts video frames as PNGs and routes them through this same path.
    nonisolated static func imageThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func videoFrame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, duration: TimeInterval?) {
        let frame = await avAssetFrame(at: url, maxPixelSize: maxPixelSize)
        if frame.image != nil { return frame }
        // AVFoundation can't open every container the player handles (notably webm
        // and mkv); libmpv decodes those, so fall back to it.
        return await MPVThumbnailer.frame(at: url, maxPixelSize: maxPixelSize)
    }

    /// A representative frame and the asset's duration in one open. The duration is
    /// a moov-atom read independent of the frame, so it is loaded even when the frame
    /// generation fails (an audio-only asset), and `nil` when AVFoundation can't read
    /// it — the webm/mkv case, where `videoFrame` falls back to libmpv.
    private nonisolated static func avAssetFrame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, duration: TimeInterval?) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // Sample ~10% in (past the often-black opening), the same relative position the
        // libmpv fallback uses, so the same content yields a comparable thumbnail across
        // codecs. Fall back to 1s when the duration is unknown.
        let position = duration.map { $0 * 0.1 } ?? 1
        let time = CMTime(seconds: position, preferredTimescale: 600)
        let image = try? await generator.image(at: time).image
        return (image, duration)
    }
}
