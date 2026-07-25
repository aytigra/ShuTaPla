//
//  ImagePlaybackEngine.swift
//  ShuTaPla
//
//  The image channel. Unlike the mpv-backed engines it has no libmpv instance:
//  it decodes the current image with `CGImageSource`, publishes it for the
//  player view, and drives a slideshow with an async timer. Pan/zoom is held as
//  an `ImageTransform` the view binds to and the engine resets on every file
//  change and fit-mode cycle. It shares the `PlaybackSource` seam with the other
//  engines so advance/previous and slideshow stepping use the same ordering.
//

import Foundation
import ImageIO

/// Pan offset and zoom scale applied to the displayed image. Reset to `.identity`
/// whenever the image changes so a new file always starts un-panned and un-zoomed.
nonisolated struct ImageTransform: Equatable, Sendable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1

    static let identity = ImageTransform()
    var isIdentity: Bool { self == .identity }

    /// Zoom by `magnification` about `pinchCenter` (screen coords, origin at the viewport
    /// centre), keeping the picture point under the pinch fixed. `newScale / scale` is the
    /// effective factor so the `minScale` floor stays consistent when it clamps. Used for both
    /// the live preview (with a `.center` anchor) and the commit, so the two never disagree.
    func zoomed(by magnification: CGFloat, about pinchCenter: CGSize, minScale: CGFloat) -> ImageTransform {
        let newScale = max(minScale, scale * magnification)
        let m = newScale / scale
        return ImageTransform(
            offset: CGSize(width: m * offset.width + (1 - m) * pinchCenter.width,
                           height: m * offset.height + (1 - m) * pinchCenter.height),
            scale: newScale)
    }

    /// Translate the offset by a screen-space drag.
    func panned(by translation: CGSize) -> ImageTransform {
        ImageTransform(
            offset: CGSize(width: offset.width + translation.width,
                           height: offset.height + translation.height),
            scale: scale)
    }

    /// Bound the offset so the scaled picture (`scale · frame`) never pulls an empty margin into
    /// the `viewport`: pan reaches the edge when larger, recenters when smaller than the viewport.
    func clamped(frame: CGSize, viewport: CGSize) -> ImageTransform {
        func limit(_ displayed: CGFloat, _ view: CGFloat) -> CGFloat { max(0, (displayed - view) / 2) }
        let lx = limit(scale * frame.width, viewport.width)
        let ly = limit(scale * frame.height, viewport.height)
        return ImageTransform(
            offset: CGSize(width: min(max(offset.width, -lx), lx),
                           height: min(max(offset.height, -ly), ly)),
            scale: scale)
    }
}

@MainActor
@Observable
final class ImagePlaybackEngine: SourceNavigating {

    /// The decoded image to display, or `nil` while loading / when stopped. A `CGImage` (not an
    /// `NSImage`) so it carries its HDR colour space straight to the player's EDR layer.
    private(set) var currentImage: CGImage?

    /// The file currently shown. Anchor for advance/previous and the slideshow.
    private(set) var currentFile: PlaylistFile?

    /// How the image is scaled to the surface. Changing it resets pan/zoom, since the
    /// transform only has meaning in `.original`.
    var fitMode: ImageFitMode = .fit {
        didSet {
            guard fitMode != oldValue else { return }
            transform = .identity
        }
    }

    /// Live pan/zoom. The player view reads and writes this through gestures.
    var transform: ImageTransform = .identity

    /// Whether the slideshow timer is running.
    private(set) var slideshowEnabled: Bool = false

    /// Seconds between slideshow advances. Changing it restarts a running timer.
    var slideshowInterval: TimeInterval = 5 {
        didSet {
            guard slideshowEnabled, slideshowInterval != oldValue else { return }
            restartSlideshowTimer()
        }
    }

    /// Supplies the next/previous file and its URL. Set by the coordinator.
    weak var source: PlaybackSource?

    /// Holds an evicted file pending until its bytes arrive, then decodes it. The player
    /// view reads `cloudLoad.pendingFile` to show the downloading placeholder.
    let cloudLoad = CloudLoadGate()

    private var loadTask: Task<Void, Never>?
    private var slideshowTask: Task<Void, Never>?

    init() {}

    // MARK: - Loading

    /// Loads and displays the image at `url`, resetting pan/zoom to identity. An evicted file
    /// is held pending by `cloudLoad` and only decoded once the live feed reports its arrival;
    /// a `.local` file decodes at once. The decode runs off the main actor so a large image
    /// doesn't hitch the advance.
    func load(_ file: PlaylistFile?, at url: URL) {
        currentFile = file
        transform = .identity
        cloudLoad.load(file) { [weak self] in
            self?.decode(at: url)
        } requestDownload: { [weak self] in
            self?.source?.requestDownload($0)
        }
    }

    /// Decodes and displays the image — run at once for a `.local` file or deferred by
    /// `cloudLoad` until an evicted file arrives.
    private func decode(at url: URL) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let decoded = await Self.decodeImage(at: url)
            guard !Task.isCancelled, let self else { return }
            self.currentImage = decoded
        }
    }

    /// Clears the displayed image and stops the slideshow.
    func stop() {
        cloudLoad.cancel()
        stopSlideshow()
        loadTask?.cancel()
        loadTask = nil
        currentImage = nil
        currentFile = nil
        transform = .identity
    }

    // Advance / previous come from `SourceNavigating` (shared with the mpv engines).

    // MARK: - Fit mode & transform

    /// Returns pan/zoom to identity without changing the image or fit mode.
    func resetTransform() { transform = .identity }

    // MARK: - Slideshow

    /// Starts (or restarts) the slideshow. An optional `interval` updates the
    /// per-tick delay; otherwise the current `slideshowInterval` is used.
    func startSlideshow(interval: TimeInterval? = nil) {
        if let interval { slideshowInterval = interval }
        slideshowEnabled = true
        restartSlideshowTimer()
    }

    /// Stops the slideshow timer. The current image stays on screen.
    func stopSlideshow() {
        slideshowEnabled = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    /// Flips the slideshow on/off.
    func toggleSlideshow() {
        slideshowEnabled ? stopSlideshow() : startSlideshow()
    }

    private func restartSlideshowTimer() {
        slideshowTask?.cancel()
        let interval = slideshowInterval
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                self.slideshowTick()
            }
        }
    }

    /// One slideshow beat: advances to the next image while the slideshow is on. The
    /// guard covers a timer task cancelled mid-sleep whose final beat still lands.
    func slideshowTick() {
        guard slideshowEnabled else { return }
        advanceToNext()
    }

    // MARK: - Decode (off main)

    /// Decodes a full-resolution image off the main actor. `kCGImageSourceDecodeToHDR` applies an
    /// HDR gain map and preserves PQ/HLG values so HDR content survives as HDR (rather than decoding
    /// to its SDR base). The `CGImage` carries its colour space to the player's EDR layer, which on
    /// a capable display renders it with extended range. `CGImage` is `Sendable`, so it crosses the
    /// actor hop directly.
    @concurrent
    private nonisolated static func decodeImage(at url: URL) async -> CGImage? {
        await url.withSecurityScopedAccess { url in
            let options: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
    }
}
