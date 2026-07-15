//
//  ThumbnailService.swift
//  ShuTaPla
//
//  Async thumbnail generation for the gallery view. Images are thumbnailed with
//  `CGImageSource`; videos with `AVAssetImageGenerator`. Results are cached in
//  memory (`NSCache`) and on disk. The disk cache is keyed by the file's content
//  fingerprint (`URL.contentFingerprint`), so the same media shares one thumbnail
//  regardless of which folder or playlist references it, and a rename or move keeps
//  the entry rather than orphaning it. The fingerprint carries its own invalidation:
//  a content change yields a new fingerprint and a fresh entry.
//
//  Generation runs off the main actor: the public entry point reads the model on
//  the main actor (including any persisted fingerprint), then hands Sendable values
//  (bookmark, relative path, size, fingerprint) to `nonisolated` workers that resolve
//  the bookmark, read the file, and return HEIC `Data` that the main actor turns back
//  into an `NSImage`. A worker that had to compute the fingerprint itself (the record
//  didn't carry one yet) reports it back in the returned `MediaMetadata`, so the
//  gallery's merge persists it and later sessions supply it without the read.
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
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
    }

    /// The app's on-disk thumbnail directory. Application Support, not Caches: the OS purges the
    /// Caches directory under disk pressure with no regard for what's still referenced, discarding
    /// thumbnails the user is actively viewing. Application Support is ours to manage (size / clear
    /// / orphan-sweep below), so the cache persists until we evict it. `static` so the playlist
    /// scan can measure its size (`defaultCacheSize`) without holding the main-actor service.
    nonisolated static var defaultCacheDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "ShuTaPla"
        return base
            .appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    /// Total bytes the app's default cache occupies — the size read the playlist scan uses to
    /// refresh the cache-pressure flag, off the main actor and without a service instance.
    nonisolated static func defaultCacheSize() async -> Int {
        await cacheSize(in: defaultCacheDirectory)
    }

    // MARK: - Public API

    /// A thumbnail for `file`, generated on first request and cached thereafter, paired
    /// with the metadata generation determined — duration and pixel dimensions for a fresh
    /// video decode, dimensions for a fresh image, and the file's size whenever the file was
    /// opened. The image is `nil` when the file can't be read or decoded (the caller shows a
    /// placeholder); the metadata is empty for a thumbnail served from cache (no file open —
    /// the caller falls back to the values persisted on the model). `maxPixelSize` is the
    /// longest edge in pixels.
    func thumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) async -> (image: NSImage?, metadata: MediaMetadata) {
        // A skipped file is wrong-type for its playlist: the decoder can't read it, so there is no
        // thumbnail to render. Keep the placeholder icon without resolving the bookmark or opening
        // the file — its size comes from the metadata service, which reads that alone.
        guard !file.isSkipped else { return (nil, MediaMetadata()) }
        let bookmark = playlist.folderBookmark
        let relativePath = file.relativePath
        let isVideo = playlist.mediaType == .video
        let fingerprint = file.fingerprint
        let recordFileSize = file.fileSizeBytes
        let recordLastModified = file.lastModified
        let isLocal = file.cloudStatus == .local
        let memKey = memoryKey(for: file, in: playlist, maxPixelSize: maxPixelSize)

        if let cached = memory.object(forKey: memKey) { return (cached, MediaMetadata()) }

        // Generation *and* decode happen off the main actor, so the cell receives a
        // ready-to-draw image and scrolling never blocks on a lazy draw-time decode.
        let produced = await Self.produceImage(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            fingerprint: fingerprint,
            recordFileSize: recordFileSize,
            recordLastModified: recordLastModified,
            isLocal: isLocal,
            cacheDirectory: cacheDirectory
        )
        guard let boxed = produced.image else { return (nil, produced.metadata) }

        memory.setObject(boxed.image, forKey: memKey, cost: Self.byteCost(of: boxed.image))
        return (boxed.image, produced.metadata)
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

    /// Cheap, disk-I/O-free key for the in-memory cache: playlist id + relative path + longest-edge
    /// pixel size + content fingerprint. The playlist's stable id is collision-free (unlike a
    /// per-process `hashValue`, which two folders' bookmarks can share and cross-paint). Folding in
    /// the fingerprint means a content change the record has picked up (a new fingerprint) keys a
    /// fresh entry, so an in-place edit isn't served a stale decode carried over from earlier in the
    /// session; an empty string stands in until the first fingerprint is known.
    private func memoryKey(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) -> NSString {
        "\(playlist.id.uuidString)|\(file.relativePath)|\(maxPixelSize)|\(file.fingerprint ?? "")" as NSString
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
            fingerprint: nil,
            recordFileSize: nil,
            recordLastModified: nil,
            cacheDirectory: cacheDirectory
        ).data
    }

    // MARK: - Cache management

    /// Total bytes the cache occupies on disk — the whole directory's footprint. Read off the
    /// main actor, since a large cache is a directory enumeration.
    func cacheSize() async -> Int {
        await Self.cacheSize(in: cacheDirectory)
    }

    /// Empties the cache directory — every generated thumbnail and any stray file (the directory
    /// itself is recreated by the next produce).
    func clearCache() async {
        await Self.clearCache(in: cacheDirectory)
    }

    /// Removes everything the cache shouldn't hold — a `.heic` whose base name (a fingerprint) is
    /// absent from `liveFingerprints`, plus any stray non-`.heic` file — keeping only the live
    /// thumbnails. `liveFingerprints` is gathered from every persisted `PlaylistFile.fingerprint`
    /// (this service holds no model context). Reports the number removed and their total bytes,
    /// measured as it sweeps: pre-measuring would mean a redundant second pass, and the sweep is
    /// the slow part regardless.
    func clearOrphans(liveFingerprints: Set<String>) async -> (removed: Int, bytes: Int) {
        await Self.clearOrphans(in: cacheDirectory, liveFingerprints: liveFingerprints)
    }

    /// Every entry in `directory`; an absent or empty directory yields none. The cache folder is
    /// ours and single-writer, so its whole contents *are* the cache: a size counts them all and a
    /// clear removes them all. Only the orphan sweep discriminates, keeping the live `.heic` set.
    private nonisolated static func cacheEntries(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    }

    /// A file the orphan sweep keeps: a `.heic` thumbnail whose fingerprint (its base name) a live
    /// record still references. Everything else — an unreferenced thumbnail or any stray file —
    /// is swept, since nothing legitimate is ever left in the cache folder but referenced thumbnails.
    private nonisolated static func isLiveThumbnail(_ file: URL, in liveFingerprints: Set<String>) -> Bool {
        file.pathExtension == "heic" && liveFingerprints.contains(file.deletingPathExtension().lastPathComponent)
    }

    @concurrent
    private nonisolated static func cacheSize(in directory: URL) async -> Int {
        cacheEntries(in: directory).reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
    }

    @concurrent
    private nonisolated static func clearCache(in directory: URL) async {
        for file in cacheEntries(in: directory) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @concurrent
    private nonisolated static func clearOrphans(
        in directory: URL, liveFingerprints: Set<String>
    ) async -> (removed: Int, bytes: Int) {
        var removed = 0
        var bytes = 0
        for file in cacheEntries(in: directory) where !isLiveThumbnail(file, in: liveFingerprints) {
            let size = file.fileSizeBytes ?? 0
            if (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
                bytes += size
            }
        }
        return (removed, bytes)
    }

    /// Writes the cache-pressure flag the Manager notice-strip banner reads. Called from the
    /// playlist scan and after a clear/orphan sweep, so the banner reflects the current footprint
    /// (and clears promptly once a sweep drops the cache back under the threshold).
    nonisolated static func publishCachePressure(bytes: Int) {
        UserDefaults.standard.set(
            AppConstants.cacheOverLimit(bytes: bytes), forKey: AppConstants.thumbnailCacheOverLimitKey)
    }

    // MARK: - Cache key

    /// The disk-cache base name for a file addressed by bookmark + relative path: its content
    /// fingerprint, which the `.heic` filename is formed from. Returns `nil` when the file can't
    /// be read (and so can't be thumbnailed). The produce path derives the same name inline
    /// (`cacheFilename`) to resolve the bookmark only once; this entry point is exercised by tests.
    @concurrent
    nonisolated static func cacheKey(bookmark: Data, relativePath: String) async -> String? {
        try? await BookmarkService.withResolvedFile(bookmark: bookmark, relativePath: relativePath) { fileURL in
            fileURL.contentFingerprint()
        }
    }

    /// The cache filename for a file, and the fingerprint to persist when this path computed one
    /// (`nil` when the caller supplied it, `nil` name-and-all when the file is unreadable). The
    /// fingerprint is already a filesystem-safe hex string, so it *is* the name — no hashing.
    private nonisolated static func cacheFilename(
        fileURL: URL, fingerprint: String?
    ) -> (name: String, computed: String?)? {
        if let fingerprint {                              // supplied by the record — no read
            return ("\(fingerprint).heic", nil)
        }
        guard let computed = fileURL.contentFingerprint() else { return nil }
        return ("\(computed).heic", computed)             // first display — compute + report
    }

    /// Whether `data` decodes as a complete image, used to reject a 0-byte or truncated
    /// disk-cache file before treating it as a hit. `statusComplete` distinguishes a
    /// fully written thumbnail from a partial one without forcing a full raster decode.
    private nonisolated static func isDecodableImage(_ data: Data) -> Bool {
        guard data.isNotEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return false }
        return true
    }

    // MARK: - Disk cache + generation

    /// Returns the on-disk thumbnail if present; otherwise generates one, writes it to the
    /// cache, and returns it. The cache filename is the file's content fingerprint: supplied by
    /// the record when it carries one (no read), otherwise computed here and reported back in the
    /// metadata so the gallery merge persists it — on a disk-cache hit too, since the name that
    /// found the `.heic` had to be formed from the fingerprint. The file's size and modification date
    /// are read from the resolved URL either way and reported back, so the record's staleness gate
    /// stays current. A fresh generation additionally reports the duration and dimensions its decode
    /// determined; a disk-cache hit reports no decode facts, and the caller keeps the model's. An
    /// unreadable file has no fingerprint, so no cache entry to name and no thumbnail — it touches
    /// the cache not at all.
    private nonisolated static func produceData(
        bookmark: Data,
        relativePath: String,
        isVideo: Bool,
        maxPixelSize: Int,
        fingerprint: String?,
        recordFileSize: Int?,
        recordLastModified: Date?,
        isLocal: Bool = true,
        cacheDirectory: URL
    ) async -> (data: Data?, metadata: MediaMetadata) {
        // One resolve + scoped-access session for the whole produce: form the cache name (which
        // may compute the fingerprint), check the disk cache, and render on a miss — rather than
        // resolving once to name and again to render.
        let produced = try? await BookmarkService.withResolvedFile(
            bookmark: bookmark, relativePath: relativePath
        ) { fileURL -> (data: Data?, metadata: MediaMetadata) in
            let fileSizeBytes = fileURL.fileSizeBytes
            let lastModified = fileURL.contentModificationDate
            // Staleness gate: a supplied fingerprint whose on-disk size *or* mtime no longer matches
            // the record's cached values means the file may have changed in place (remove-sound, an
            // edit, or a different file at the same path). Recompute the fingerprint from the current
            // bytes to decide — comparing against a value the record actually holds, so an unset
            // size/mtime (a pre-mtime row) doesn't fire the gate but is backfilled by the reported
            // metadata below.
            // An evicted file (`!isLocal`) is never read from: the staleness gate never fires (no
            // fingerprint recompute), and a record with no stored fingerprint can't be addressed in
            // the cache without reading its bytes — so it stays on the placeholder.
            let gateFired = isLocal && fingerprint != nil
                && ((recordFileSize != nil && fileSizeBytes != recordFileSize)
                    || (recordLastModified != nil && lastModified != recordLastModified))
            guard isLocal || fingerprint != nil else {
                return (nil, MediaMetadata(fileSizeBytes: fileSizeBytes, lastModified: lastModified))
            }
            guard let named = cacheFilename(fileURL: fileURL, fingerprint: gateFired ? nil : fingerprint) else {
                return (nil, MediaMetadata(fileSizeBytes: fileSizeBytes, lastModified: lastModified))
            }
            // The gate fired but the recomputed fingerprint still matches the supplied one → the
            // content is the same (a benign touch: copy, re-download of identical bytes). Only a
            // genuine fingerprint move forces a fresh render past the disk hit.
            let contentChanged = gateFired && named.computed != fingerprint
            // Report a fingerprint only when this path computed one (`nil` when supplied), so the
            // merge fills a `nil` record and leaves a matching one untouched. Size and mtime are
            // always reported, refreshing a stale/absent staleness value so the gate stops re-firing.
            let hitMetadata = MediaMetadata(
                fileSizeBytes: fileSizeBytes, fingerprint: named.computed, lastModified: lastModified)
            let diskURL = cacheDirectory.appending(path: named.name)
            if !contentChanged, let data = try? Data(contentsOf: diskURL) {
                if isDecodableImage(data) { return (data, hitMetadata) }
                // A 0-byte or truncated cache file (an interrupted prior write) reads fine
                // but can't be decoded into a thumbnail — without this it would "hit"
                // forever and leave the cell stuck on a placeholder. Drop it and regenerate.
                try? FileManager.default.removeItem(at: diskURL)
            }
            // Past here lies the source read/decode. An evicted file's disk hit (above) is served, but
            // a miss stays on the placeholder rather than fetching the bytes from the cloud to render.
            guard isLocal else { return (nil, hitMetadata) }

            var rendered = await renderThumbnail(at: fileURL, isVideo: isVideo, maxPixelSize: maxPixelSize)
            rendered.metadata.fileSizeBytes = fileSizeBytes
            rendered.metadata.lastModified = lastModified
            // A file that opens (so a fingerprint could be computed) but fails to render persists no
            // fingerprint: set it only past this guard, so a corrupt / 0-byte file never keys the
            // cache or collapses into a bogus duplicate group.
            guard let data = rendered.data else { return (nil, rendered.metadata) }
            rendered.metadata.fingerprint = named.computed
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: diskURL)
            return (data, rendered.metadata)
        }
        return produced ?? (nil, MediaMetadata())
    }

    /// Like `produceData`, but additionally decodes the encoded bytes into a fully
    /// rasterized `NSImage` off the main actor. Wrapping the result lets it cross
    /// back to the main actor without a draw-time decode on the scroll path. Carries
    /// the metadata `produceData` reported through unchanged.
    @concurrent
    private nonisolated static func produceImage(
        bookmark: Data,
        relativePath: String,
        isVideo: Bool,
        maxPixelSize: Int,
        fingerprint: String?,
        recordFileSize: Int?,
        recordLastModified: Date?,
        isLocal: Bool = true,
        cacheDirectory: URL
    ) async -> (image: SendableImage?, metadata: MediaMetadata) {
        let produced = await produceData(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            fingerprint: fingerprint,
            recordFileSize: recordFileSize,
            recordLastModified: recordLastModified,
            isLocal: isLocal,
            cacheDirectory: cacheDirectory
        )
        guard let data = produced.data else { return (nil, produced.metadata) }

        // `cgImage` forces the decode here, off-main; `NSImage(cgImage:)` then wraps
        // an already-decoded bitmap so no lazy decode happens when the cell draws.
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return (nil, produced.metadata) }
        return (SendableImage(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))), produced.metadata)
    }

    // MARK: - Generation

    /// Renders a thumbnail for a file on disk and encodes it as HEIC, reporting the
    /// media's metadata alongside it: duration and dimensions for a video (a frame decode
    /// determines them anyway), pixel dimensions for a still (its header, no pixel decode).
    /// File size is the caller's, so it's left `nil` here. Used by `produceData` and
    /// exercised directly by tests. `@concurrent` so the CPU-bound encode is guaranteed off
    /// the main actor even for a caller already on it, rather than relying on the one entry
    /// point that happens to hop.
    @concurrent
    nonisolated static func renderThumbnail(at fileURL: URL, isVideo: Bool, maxPixelSize: Int) async -> (data: Data?, metadata: MediaMetadata) {
        if isVideo {
            let frame = await videoFrame(at: fileURL, maxPixelSize: maxPixelSize)
            guard let cgImage = frame.image else { return (nil, frame.metadata) }
            return (encodeHEIC(cgImage), frame.metadata)
        }
        guard let cgImage = imageThumbnail(at: fileURL, maxPixelSize: maxPixelSize) else { return (nil, MediaMetadata()) }
        let size = fileURL.imagePixelSize
        return (encodeHEIC(cgImage), MediaMetadata(width: size?.width, height: size?.height))
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

    private nonisolated static func videoFrame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, metadata: MediaMetadata) {
        let frame = await avAssetFrame(at: url, maxPixelSize: maxPixelSize)
        if frame.image != nil { return frame }
        // AVFoundation can't open every container the player handles (notably webm
        // and mkv); libmpv decodes those, so fall back to it.
        return await MPVThumbnailer.frame(at: url, maxPixelSize: maxPixelSize)
    }

    /// A representative frame and the asset's metadata — duration and display dimensions —
    /// in one open. The metadata is a moov-atom read independent of the frame, so it is
    /// loaded even when frame generation fails (an audio-only asset), and its fields are
    /// `nil` when AVFoundation can't read them — the webm/mkv case, where `videoFrame`
    /// falls back to libmpv.
    private nonisolated static func avAssetFrame(at url: URL, maxPixelSize: Int) async -> (image: CGImage?, metadata: MediaMetadata) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let duration = await asset.playableDuration()
        let size = await asset.displayPixelSize()
        // Sample ~10% in (past the often-black opening), the same relative position the
        // libmpv fallback uses, so the same content yields a comparable thumbnail across
        // codecs. Fall back to 1s when the duration is unknown.
        let position = duration.map { $0 * 0.1 } ?? 1
        let time = CMTime(seconds: position, preferredTimescale: 600)
        let image = try? await generator.image(at: time).image
        return (image, MediaMetadata(duration: duration, width: size?.width, height: size?.height))
    }
}
