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
//  `nonisolated` workers that resolve the bookmark, read the file, and return PNG
//  `Data` that the main actor turns back into an `NSImage`.
//

import Foundation
import AppKit
import AVFoundation
import ImageIO
import CryptoKit
import Observation

@MainActor
@Observable
final class ThumbnailService {

    /// Decoded thumbnails, keyed by cache key. Spares re-reads while scrolling.
    @ObservationIgnored private let memory = NSCache<NSString, NSImage>()

    /// Where generated thumbnails are persisted between launches.
    @ObservationIgnored private let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
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

    /// A thumbnail for `file`, generated on first request and cached thereafter.
    /// Returns `nil` when the file can't be read or decoded (the caller shows a
    /// placeholder). `maxPixelSize` is the longest edge in pixels.
    func thumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) async -> NSImage? {
        let bookmark = playlist.folderBookmark
        let relativePath = file.relativePath
        let isVideo = playlist.mediaType == .video
        let memKey = memoryKey(for: file, in: playlist, maxPixelSize: maxPixelSize)

        if let cached = memory.object(forKey: memKey) { return cached }

        guard let key = await Self.cacheKey(
            bookmark: bookmark, relativePath: relativePath, maxPixelSize: maxPixelSize
        ) else { return nil }

        // Generation *and* decode happen off the main actor, so the cell receives a
        // ready-to-draw image and scrolling never blocks on a lazy draw-time decode.
        guard let boxed = await Self.produceImage(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            key: key,
            cacheDirectory: cacheDirectory
        ) else { return nil }

        memory.setObject(boxed.image, forKey: memKey)
        return boxed.image
    }

    /// A synchronous in-memory hit for the scroll-hot path — no disk I/O, so a
    /// cell that has been shown before paints its thumbnail immediately without a
    /// placeholder flash. Returns `nil` on a miss; the caller then awaits
    /// `thumbnail(for:in:maxPixelSize:)` to generate it off the main actor.
    func cachedThumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) -> NSImage? {
        memory.object(forKey: memoryKey(for: file, in: playlist, maxPixelSize: maxPixelSize))
    }

    /// Cheap, disk-I/O-free key for the in-memory cache: folder + relative path +
    /// size. The on-disk cache keys additionally by modification date; an
    /// in-memory entry is refreshed when the file is renamed (its relative path
    /// changes) or on the next launch.
    private func memoryKey(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) -> NSString {
        "\(playlist.folderBookmark.hashValue)|\(file.relativePath)|\(maxPixelSize)" as NSString
    }

    /// Disk-cached thumbnail bytes for a file addressed by bookmark + relative
    /// path, without the in-memory `NSImage` layer. Used by the gallery's higher
    /// level path and exercised directly by tests.
    func thumbnailData(bookmark: Data, relativePath: String, isVideo: Bool, maxPixelSize: Int) async -> Data? {
        guard let key = await Self.cacheKey(
            bookmark: bookmark, relativePath: relativePath, maxPixelSize: maxPixelSize
        ) else { return nil }
        return await Self.produceData(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            key: key,
            cacheDirectory: cacheDirectory
        )
    }

    // MARK: - Cache key

    /// `<relativePath>|<modDate>|<size>` hashed to a filesystem-safe name. A
    /// changed modification date yields a new key, invalidating the old thumbnail.
    /// Returns `nil` when the file is gone.
    @concurrent
    nonisolated static func cacheKey(bookmark: Data, relativePath: String, maxPixelSize: Int) async -> String? {
        guard let resolved = try? BookmarkService.resolve(bookmark) else { return nil }
        let didAccess = resolved.url.startAccessingSecurityScopedResource()
        defer { if didAccess { resolved.url.stopAccessingSecurityScopedResource() } }

        let fileURL = resolved.url.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let stamp = modDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "0"
        return digest("\(relativePath)|\(stamp)|\(maxPixelSize)")
    }

    private nonisolated static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Disk cache + generation

    /// Returns the on-disk thumbnail if present; otherwise generates one, writes
    /// it to the cache, and returns it. The disk-hit path skips generation.
    private nonisolated static func produceData(
        bookmark: Data,
        relativePath: String,
        isVideo: Bool,
        maxPixelSize: Int,
        key: String,
        cacheDirectory: URL
    ) async -> Data? {
        let diskURL = cacheDirectory.appending(path: "\(key).png")
        if let data = try? Data(contentsOf: diskURL) { return data }

        guard let resolved = try? BookmarkService.resolve(bookmark) else { return nil }
        let didAccess = resolved.url.startAccessingSecurityScopedResource()
        defer { if didAccess { resolved.url.stopAccessingSecurityScopedResource() } }

        let fileURL = resolved.url.appending(path: relativePath)
        guard let data = await renderThumbnail(at: fileURL, isVideo: isVideo, maxPixelSize: maxPixelSize) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: diskURL)
        return data
    }

    /// Like `produceData`, but additionally decodes the PNG into a fully
    /// rasterized `NSImage` off the main actor. Wrapping the result lets it cross
    /// back to the main actor without a draw-time decode on the scroll path.
    @concurrent
    private nonisolated static func produceImage(
        bookmark: Data,
        relativePath: String,
        isVideo: Bool,
        maxPixelSize: Int,
        key: String,
        cacheDirectory: URL
    ) async -> SendableImage? {
        guard let data = await produceData(
            bookmark: bookmark,
            relativePath: relativePath,
            isVideo: isVideo,
            maxPixelSize: maxPixelSize,
            key: key,
            cacheDirectory: cacheDirectory
        ) else { return nil }

        // `cgImage` forces the decode here, off-main; `NSImage(cgImage:)` then wraps
        // an already-decoded bitmap so no lazy decode happens when the cell draws.
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        return SendableImage(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    // MARK: - Generation

    /// Renders a thumbnail for a file on disk and encodes it as PNG. Used by
    /// `produceData` and exercised directly by tests.
    nonisolated static func renderThumbnail(at fileURL: URL, isVideo: Bool, maxPixelSize: Int) async -> Data? {
        let cgImage = isVideo
            ? await videoFrame(at: fileURL, maxPixelSize: maxPixelSize)
            : imageThumbnail(at: fileURL, maxPixelSize: maxPixelSize)
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private nonisolated static func imageThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func videoFrame(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
