//
//  MediaPreview.swift
//  ShuTaPla
//
//  The Manager "peek": a single file shown on its own — video or image — without
//  starting the playlist, claiming a `PlaybackCoordinator` channel, or entering
//  Player mode. It owns its own engines, deliberately separate from the coordinator,
//  so previewing leaves the playlist, the live audio channel, and the window mode
//  exactly as they were.
//
//  A previewed video plays from the beginning, looping forever (so it never reaches
//  end-of-file), at its playlist's volume, with `source` left nil so it never
//  advances past the one file. An image is decoded and shown fit-to-window. The
//  scoped-folder session opened on the file's folder lives for the duration of the
//  preview and is released on close.
//

import Foundation
import AppKit

@MainActor
@Observable
final class MediaPreview {

    /// The file being previewed, or `nil` when the preview is closed.
    private(set) var file: PlaylistFile?

    /// Whether a preview is on screen.
    var isOpen: Bool { file != nil }

    /// The previewed file's type — chooses the render surface. `nil` when closed.
    var mediaType: MediaType? { file?.playlist?.mediaType }

    /// The image engine's decoded picture, for the image preview. No libmpv.
    var image: NSImage? { imageEngine.currentImage }

    /// The surface the video engine renders into, once a video preview has run.
    var videoRenderView: MPVVideoView? { (videoEngine as? VideoPlaybackEngine)?.renderView }

    /// The video's live position / length, driving the preview's progress strip. Both 0
    /// while an image is previewed or nothing is.
    var currentTime: TimeInterval { videoEngine?.currentTime ?? 0 }
    var duration: TimeInterval { videoEngine?.duration ?? 0 }

    /// The previewed media's natural size, for the card's aspect ratio. The model's cached
    /// pixel size wins when known — present the instant the preview opens, so the card takes
    /// its true shape with no wait. The live source is the fallback for the race where nothing
    /// is cached yet: an image's decoded size, a video's mpv display size once it reports.
    /// `nil` until known, so the card waits for a real shape rather than appearing square and
    /// resizing.
    var contentSize: CGSize? {
        if let cached = file?.pixelSize { return cached }
        switch mediaType {
        case .image: return image?.size
        case .video:
            let size = videoEngine?.videoSize ?? .zero
            return size.width > 0 && size.height > 0 ? size : nil
        case .audio, .none: return nil
        }
    }

    private let folderAccess: ScopedFolderAccess
    private let makeVideoEngine: () throws -> MPVPlaybackEngine

    /// Built on first video preview so an image-only session never spins up libmpv; kept
    /// alive across previews. Internal (like the coordinator's) so tests can inspect it.
    var videoEngine: MPVPlaybackEngine?

    /// Cheap (no libmpv), so it always exists; reuses the coordinator image path's off-main
    /// decode and per-decode scoped access.
    let imageEngine: ImagePlaybackEngine

    /// The playlist whose scoped-folder session is open for the current preview, so `close`
    /// releases exactly it.
    private var sessionPlaylistID: UUID?

    init(
        folderAccess: ScopedFolderAccess,
        imageEngine: ImagePlaybackEngine = ImagePlaybackEngine(),
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try VideoPlaybackEngine() }
    ) {
        self.folderAccess = folderAccess
        self.imageEngine = imageEngine
        self.makeVideoEngine = makeVideoEngine
    }

    // MARK: - Open / close

    /// Opens the preview on `file`, or closes it if one is already open — the `[space]` toggle.
    func toggle(_ file: PlaylistFile) {
        isOpen ? close() : open(file)
    }

    /// Shows `file` on its own engine. A no-op for audio (never previewed) or when the file's
    /// folder can't be reached.
    private func open(_ file: PlaylistFile) {
        guard let playlist = file.playlist, playlist.mediaType != .audio,
              let folder = folderAccess.begin(for: playlist) else { return }
        sessionPlaylistID = playlist.id
        self.file = file
        let url = folder.appending(path: file.relativePath)

        switch playlist.mediaType {
        case .image:
            imageEngine.load(file, at: url)
        case .video:
            guard let engine = ensureVideoEngine() else { close(); return }
            engine.source = nil                                    // a preview is one file; never advance
            engine.volume = Double(playlist.preferences.volume) * 100
            engine.load(file, at: url)                             // always from the beginning
            engine.setLooping(true)                               // after load, which clears looping
        case .audio:
            break
        }
    }

    /// Closes the preview: stops the engine, releases the scoped session, and clears the file.
    func close() {
        videoEngine?.stop()
        imageEngine.stop()
        if let sessionPlaylistID { folderAccess.end(for: sessionPlaylistID) }
        sessionPlaylistID = nil
        file = nil
    }

    /// Tears the video engine down (app exit).
    func shutdown() {
        close()
        videoEngine?.shutdown()
        videoEngine = nil
    }

    private func ensureVideoEngine() -> MPVPlaybackEngine? {
        if let videoEngine { return videoEngine }
        guard let engine = try? makeVideoEngine() else { return nil }
        videoEngine = engine
        return engine
    }
}
