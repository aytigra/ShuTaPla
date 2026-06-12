//
//  PlaybackCoordinator.swift
//  ShuTaPla
//
//  The conductor between the UI and the three playback engines. It owns one
//  visual channel (video XOR image) and one independent audio channel, starts and
//  stops playlists on them, and keeps each playlist's persisted Stopped/Playing/
//  Paused state in step. Suppression — the pause overlay's global halt — is a
//  transient layer on top: effective playback is a playlist's own `.playing` state
//  AND `!isSuppressed`, and lifting suppression resumes only the playlists that
//  were Playing, leaving Paused ones paused.
//
//  It is the engines' `PlaybackSource`: an engine asks it for the next/previous
//  file (the owning playlist's `playbackSequence`, found from the current file's
//  `playlist`) and for a URL to load, resolved through the folder's scoped-access
//  session. The mpv engines are built on first use so an images-only or audio-only
//  session never spins up an unused libmpv instance.
//

import Foundation

@MainActor
@Observable
final class PlaybackCoordinator: PlaybackSource {

    /// Transient global halt from the pause overlay. Never persisted, and the
    /// per-playlist states are untouched while it is set.
    private(set) var isSuppressed = false

    /// The playlist on the shared visual channel (video or image), or `nil`.
    private(set) var visualPlaylist: Playlist?

    /// Which engine the visual channel is using, so suspend/resume/stop route to
    /// the right one without re-reading `visualPlaylist.mediaType` (which could
    /// drift if the model changed underneath).
    private(set) var visualKind: MediaType?

    /// The playlist on the independent audio channel, or `nil`.
    private(set) var audioPlaylist: Playlist?

    /// The image engine — cheap (no libmpv), so it always exists. Player views read
    /// its `currentImage`/`transform` directly.
    let imageEngine: ImagePlaybackEngine

    /// The view the video engine renders into, once a video has played. `nil` until
    /// then (or when the visual channel is audio-configured, as in tests).
    var videoRenderView: MPVVideoView? { (videoEngine as? VideoPlaybackEngine)?.renderView }

    private let bookmarkService: BookmarkService
    private let defaultSlideshowInterval: () -> TimeInterval

    private let makeVideoEngine: () throws -> MPVPlaybackEngine
    private let makeAudioEngine: () throws -> MPVPlaybackEngine
    private var videoEngine: MPVPlaybackEngine?
    private var audioEngine: MPVPlaybackEngine?

    // Open scoped-access folder per active playlist, for `url(for:)`. The bookmark
    // is kept alongside so the matching `stopAccess` can be issued on stop.
    private var folderURLByPlaylist: [UUID: URL] = [:]
    private var bookmarkByPlaylist: [UUID: Data] = [:]

    /// `makeVideoEngine`/`makeAudioEngine` are injectable so tests substitute the
    /// window-free audio engine for the video slot, avoiding Vulkan startup.
    init(
        bookmarkService: BookmarkService,
        defaultSlideshowInterval: @escaping () -> TimeInterval = { 5 },
        imageEngine: ImagePlaybackEngine = ImagePlaybackEngine(),
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try VideoPlaybackEngine() },
        makeAudioEngine: @escaping () throws -> MPVPlaybackEngine = { try AudioPlaybackEngine() }
    ) {
        self.bookmarkService = bookmarkService
        self.defaultSlideshowInterval = defaultSlideshowInterval
        self.imageEngine = imageEngine
        self.makeVideoEngine = makeVideoEngine
        self.makeAudioEngine = makeAudioEngine
        imageEngine.source = self
    }

    /// Tears down the engines and releases every scoped-access session.
    func shutdown() {
        videoEngine?.shutdown()
        audioEngine?.shutdown()
        imageEngine.stop()
        for bookmark in bookmarkByPlaylist.values { bookmarkService.stopAccess(to: bookmark) }
        folderURLByPlaylist.removeAll()
        bookmarkByPlaylist.removeAll()
    }

    // MARK: - Starting playback

    /// Starts `playlist` on its channel, beginning at `file` (or its remembered /
    /// first file). Starting a visual playlist stops whichever visual playlist was
    /// playing; audio is independent.
    func play(_ playlist: Playlist, startingAt file: PlaylistFile? = nil) {
        switch playlist.mediaType {
        case .video, .image: startVisual(playlist, startingAt: file)
        case .audio: startAudio(playlist, startingAt: file)
        }
    }

    private func startVisual(_ playlist: Playlist, startingAt file: PlaylistFile?) {
        if let current = visualPlaylist, current !== playlist { stopVisual() }
        guard let folder = beginFolderAccess(for: playlist) else { return }

        let start = startFile(for: playlist, requested: file)
        visualPlaylist = playlist
        visualKind = playlist.mediaType
        playlist.playbackState = .playing
        if let start { playlist.currentFileID = start.id }

        switch playlist.mediaType {
        case .image:
            imageEngine.source = self
            if let start { imageEngine.load(start, at: folder.appending(path: start.relativePath)) }
            if !isSuppressed { applySlideshow(for: playlist) }
        default:   // video
            guard let engine = ensureVideoEngine() else { return }
            engine.source = self
            engine.volume = volume(for: playlist)
            if let start { engine.load(start, at: folder.appending(path: start.relativePath)) }
            if isSuppressed { engine.pause() }
        }
    }

    private func startAudio(_ playlist: Playlist, startingAt file: PlaylistFile?) {
        if let current = audioPlaylist, current !== playlist { stopAudio() }
        guard let folder = beginFolderAccess(for: playlist),
              let engine = ensureAudioEngine() else { return }

        let start = startFile(for: playlist, requested: file)
        audioPlaylist = playlist
        playlist.playbackState = .playing
        if let start { playlist.currentFileID = start.id }

        engine.source = self
        engine.volume = volume(for: playlist)
        if let start { engine.load(start, at: folder.appending(path: start.relativePath)) }
        if isSuppressed { engine.pause() }
    }

    // MARK: - Stopping

    /// Stops `playlist` on whichever channel it occupies and marks it Stopped.
    func stop(_ playlist: Playlist) {
        if visualPlaylist === playlist { stopVisual() }
        else if audioPlaylist === playlist { stopAudio() }
        else { playlist.playbackState = .stopped }
    }

    private func stopVisual() {
        guard let playlist = visualPlaylist else { return }
        switch visualKind {
        case .image: imageEngine.stop()
        default: videoEngine?.stop()
        }
        playlist.playbackState = .stopped
        endFolderAccess(for: playlist.id)
        visualPlaylist = nil
        visualKind = nil
    }

    private func stopAudio() {
        guard let playlist = audioPlaylist else { return }
        audioEngine?.stop()
        playlist.playbackState = .stopped
        endFolderAccess(for: playlist.id)
        audioPlaylist = nil
    }

    // MARK: - Per-playlist pause / unpause

    /// Pauses a playing playlist, recording its own Paused state. A no-op while
    /// suppressed defers the engine pause to suppression, but the state still flips.
    func pause(_ playlist: Playlist) {
        guard isActive(playlist) else { return }
        playlist.playbackState = .paused
        if !isSuppressed { suspend(playlist) }
    }

    /// Resumes a paused playlist, restoring its Playing state.
    func unpause(_ playlist: Playlist) {
        guard isActive(playlist) else { return }
        playlist.playbackState = .playing
        if !isSuppressed { resume(playlist) }
    }

    func togglePause(_ playlist: Playlist) {
        playlist.playbackState == .playing ? pause(playlist) : unpause(playlist)
    }

    // MARK: - Suppression (pause overlay)

    /// Halts both channels without touching their persisted states.
    func suppress() {
        guard !isSuppressed else { return }
        isSuppressed = true
        if let playlist = visualPlaylist { suspend(playlist) }
        if let playlist = audioPlaylist { suspend(playlist) }
    }

    /// Lifts the halt: Playing playlists resume, Paused ones stay paused.
    func unsuppress() {
        guard isSuppressed else { return }
        isSuppressed = false
        if let playlist = visualPlaylist, playlist.playbackState == .playing { resume(playlist) }
        if let playlist = audioPlaylist, playlist.playbackState == .playing { resume(playlist) }
    }

    // MARK: - Advance / previous

    /// Advances `playlist` to the next file in its playback sequence (wrapping).
    func next(_ playlist: Playlist) { advance(playlist, forward: true) }

    /// Steps `playlist` back to the previous file (wrapping).
    func previous(_ playlist: Playlist) { advance(playlist, forward: false) }

    private func advance(_ playlist: Playlist, forward: Bool) {
        switch channel(of: playlist) {
        case .visualImage:
            forward ? imageEngine.advanceToNext() : imageEngine.returnToPrevious()
            playlist.currentFileID = imageEngine.currentFile?.id ?? playlist.currentFileID
        case .visualVideo:
            forward ? videoEngine?.advanceToNext() : videoEngine?.returnToPrevious()
            playlist.currentFileID = videoEngine?.currentFile?.id ?? playlist.currentFileID
        case .audio:
            forward ? audioEngine?.advanceToNext() : audioEngine?.returnToPrevious()
            playlist.currentFileID = audioEngine?.currentFile?.id ?? playlist.currentFileID
        case nil:
            break
        }
    }

    // MARK: - PlaybackSource

    func fileAfter(_ current: PlaylistFile?) -> PlaylistFile? {
        guard let current, let playlist = current.playlist else { return nil }
        return playlist.playbackSequence.cyclicSuccessor { $0.id == current.id }
    }

    func fileBefore(_ current: PlaylistFile?) -> PlaylistFile? {
        guard let current, let playlist = current.playlist else { return nil }
        return playlist.playbackSequence.cyclicPredecessor { $0.id == current.id }
    }

    func url(for file: PlaylistFile) -> URL? {
        guard let playlist = file.playlist, let folder = folderURLByPlaylist[playlist.id] else { return nil }
        return folder.appending(path: file.relativePath)
    }

    // MARK: - Channel routing

    private enum Channel { case visualVideo, visualImage, audio }

    private func channel(of playlist: Playlist) -> Channel? {
        if visualPlaylist === playlist { return visualKind == .image ? .visualImage : .visualVideo }
        if audioPlaylist === playlist { return .audio }
        return nil
    }

    private func isActive(_ playlist: Playlist) -> Bool { channel(of: playlist) != nil }

    /// Halts a playlist's engine without changing its persisted state.
    private func suspend(_ playlist: Playlist) {
        switch channel(of: playlist) {
        case .visualImage: imageEngine.stopSlideshow()
        case .visualVideo: videoEngine?.pause()
        case .audio: audioEngine?.pause()
        case nil: break
        }
    }

    /// Resumes a playlist's engine (the inverse of `suspend`).
    private func resume(_ playlist: Playlist) {
        switch channel(of: playlist) {
        case .visualImage: applySlideshow(for: playlist)
        case .visualVideo: videoEngine?.play()
        case .audio: audioEngine?.play()
        case nil: break
        }
    }

    // MARK: - Helpers

    private func applySlideshow(for playlist: Playlist) {
        guard playlist.preferences.slideshowEnabled else { return }
        imageEngine.startSlideshow(interval: playlist.preferences.slideshowInterval ?? defaultSlideshowInterval())
    }

    /// The file to start at: the explicit request, else the remembered current
    /// file if it is still in the sequence, else the first file.
    private func startFile(for playlist: Playlist, requested: PlaylistFile?) -> PlaylistFile? {
        if let requested { return requested }
        let sequence = playlist.playbackSequence
        if let id = playlist.currentFileID, let remembered = sequence.first(where: { $0.id == id }) {
            return remembered
        }
        return sequence.first
    }

    /// mpv volume (0–100) from the playlist's stored 0.0–1.0 preference.
    private func volume(for playlist: Playlist) -> Double {
        Double(playlist.preferences.volume) * 100
    }

    private func ensureVideoEngine() -> MPVPlaybackEngine? {
        if let videoEngine { return videoEngine }
        guard let engine = try? makeVideoEngine() else { return nil }
        videoEngine = engine
        return engine
    }

    private func ensureAudioEngine() -> MPVPlaybackEngine? {
        if let audioEngine { return audioEngine }
        guard let engine = try? makeAudioEngine() else { return nil }
        audioEngine = engine
        return engine
    }

    // MARK: - Scoped folder access

    private func beginFolderAccess(for playlist: Playlist) -> URL? {
        if let url = folderURLByPlaylist[playlist.id] { return url }
        guard let url = try? bookmarkService.startAccess(to: playlist.folderBookmark) else { return nil }
        folderURLByPlaylist[playlist.id] = url
        bookmarkByPlaylist[playlist.id] = playlist.folderBookmark
        return url
    }

    private func endFolderAccess(for playlistID: UUID) {
        guard let bookmark = bookmarkByPlaylist[playlistID] else { return }
        bookmarkService.stopAccess(to: bookmark)
        folderURLByPlaylist[playlistID] = nil
        bookmarkByPlaylist[playlistID] = nil
    }
}
