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
import AppKit
import ImageIO

/// Pan offset and zoom scale applied to the displayed image. Reset to `.identity`
/// whenever the image changes so a new file always starts un-panned and un-zoomed.
nonisolated struct ImageTransform: Equatable, Sendable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1

    static let identity = ImageTransform()
    var isIdentity: Bool { self == .identity }
}

@MainActor
@Observable
final class ImagePlaybackEngine: SourceNavigating {

    /// The decoded image to display, or `nil` while loading / when stopped.
    private(set) var currentImage: NSImage?

    /// The file currently shown. Anchor for advance/previous and the slideshow.
    private(set) var currentFile: PlaylistFile?

    /// How the image is scaled to the surface. Cycle with `cycleFitMode()`.
    var fitMode: ImageFitMode = .fit

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

    private var loadTask: Task<Void, Never>?
    private var slideshowTask: Task<Void, Never>?

    init() {}

    // MARK: - Loading

    /// Loads and displays the image at `url`, resetting pan/zoom to identity. The
    /// decode runs off the main actor so a large image doesn't hitch the advance.
    func load(_ file: PlaylistFile?, at url: URL) {
        currentFile = file
        transform = .identity
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let decoded = await Self.decodeImage(at: url)
            guard !Task.isCancelled, let self else { return }
            self.currentImage = decoded?.image
        }
    }

    /// Clears the displayed image and stops the slideshow.
    func stop() {
        stopSlideshow()
        loadTask?.cancel()
        loadTask = nil
        currentImage = nil
        currentFile = nil
        transform = .identity
    }

    // Advance / previous come from `SourceNavigating` (shared with the mpv engines).

    // MARK: - Fit mode & transform

    /// Cycles fit → cover → original → fit and resets pan/zoom.
    func cycleFitMode() {
        switch fitMode {
        case .fit: fitMode = .cover
        case .cover: fitMode = .original
        case .original: fitMode = .fit
        }
        transform = .identity
    }

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
                self.advanceToNext()
            }
        }
    }

    // MARK: - Decode (off main)

    /// Decodes a full-resolution image off the main actor. `kCGImageSourceShouldAllowFloat`
    /// preserves wide-gamut/HDR pixel data for display in an EDR-capable layer. The
    /// `NSImage` is built from an already-decoded `CGImage`, so the main actor never
    /// pays a draw-time decode.
    @concurrent
    private nonisolated static func decodeImage(at url: URL) async -> SendableImage? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let options: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SendableImage(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }
}
