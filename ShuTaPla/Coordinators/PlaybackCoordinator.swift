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
//  file (the owning playlist's `sequence`, found from the current file's
//  `playlist`) and for a URL to load, resolved through the folder's scoped-access
//  session. The mpv engines are built on first use so an images-only or audio-only
//  session never spins up an unused libmpv instance.
//
//  This primary declaration owns the stored state, the lifecycle that claims and
//  releases channels (`play`/`stop`/`reconstruct`), suppression, the overlay halt,
//  and the channel routing every partial reads. The read-only display surface and
//  the loop/seek/volume/slideshow setters live in `+Controls`, the in-channel
//  transport in `+Transport`, and file-position persistence plus the `PlaybackSource`
//  conformance in `+Persistence`.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class PlaybackCoordinator: PlaybackSource {

    /// Transient global halt from the pause overlay. Never persisted, and the
    /// per-playlist states are untouched while it is set.
    private(set) var isSuppressed = false

    /// The playlist on the shared visual channel (video or image), or `nil`.
    private(set) var liveVisualPlaylist: Playlist?

    /// Which engine the visual channel is using, so suspend/resume/stop route to
    /// the right one without re-reading `liveVisualPlaylist.mediaType` (which could
    /// drift if the model changed underneath).
    private(set) var visualKind: MediaType?

    /// The playlist on the independent audio channel, or `nil`.
    private(set) var liveAudioPlaylist: Playlist?

    /// Transiently halts the visual channel's advancement (slideshow timer / video)
    /// while a non-suppressing overlay edits its files, without changing persisted
    /// state or showing the pause overlay. Balanced by `resumeVisualForOverlay()`.
    private(set) var visualHaltedForOverlay = false

    /// Whether the visual channel is effectively playing right now — its playlist is `.playing`
    /// and nothing is suppressing it. Drives the player's display-sleep block and cursor
    /// auto-hide, which both arm only while the picture is actually moving.
    var isVisuallyPlaying: Bool {
        liveVisualPlaylist?.playbackState == .playing && !isSuppressed
    }

    /// The image engine — cheap (no libmpv), so it always exists. Player views read
    /// its `currentImage`/`transform` directly.
    let imageEngine: ImagePlaybackEngine

    /// The view the video engine renders into, once a video has played. `nil` until
    /// then (or when the visual channel is audio-configured, as in tests).
    var videoRenderView: MPVVideoView? { (videoEngine as? VideoPlaybackEngine)?.renderView }

    /// Per-playlist scoped-folder sessions, resolving file URLs and reference-counting the
    /// security-scoped access each active playlist holds to its folder.
    let folderAccess: ScopedFolderAccess

    /// Global defaults a playlist's unset (`nil`) preferences fall back to — the slideshow
    /// interval and file-position persistence the coordinator resolves per playlist. Held live
    /// (not snapshotted), so editing a global default in Settings takes effect immediately.
    let globalSettings: GlobalSettings

    /// The live cloud-status feed. The coordinator drives its per-channel query lifecycle from
    /// the same claim/release points that own the channels, so a channel's folder watch tracks
    /// whichever playlist is live on it.
    let cloudFileService: CloudFileService

    /// The shared sequence provider. The find-target reads (`startFile`, `fileAfter`/`fileBefore`,
    /// `jump`, `reconcile`) and the prefetch read in `setCurrentFile` all resolve a playlist's
    /// sequence through it, so within one synchronous advance they hit a single memoized entry —
    /// the same one the Manager and overlays bind to.
    let sequences: PlaybackSequences

    /// The repeating "write the live position" loop, run while a timeline channel plays so a
    /// crash or hard quit still leaves a recent resume point. Started lazily, cancelled on shutdown.
    var positionPersistTask: Task<Void, Never>?

    /// How often `positionPersistTask` writes the live position to disk.
    let positionPersistInterval: TimeInterval = 5

    private let makeVideoEngine: () throws -> MPVPlaybackEngine
    private let makeAudioEngine: () throws -> MPVPlaybackEngine
    var videoEngine: MPVPlaybackEngine?
    var audioEngine: MPVPlaybackEngine?

    /// `makeVideoEngine`/`makeAudioEngine` are injectable so tests substitute the
    /// window-free audio engine for the video slot, avoiding Vulkan startup.
    init(
        folderAccess: ScopedFolderAccess,
        globalSettings: GlobalSettings = GlobalSettings(),
        cloudFileService: CloudFileService = CloudFileService(),
        sequences: PlaybackSequences,
        imageEngine: ImagePlaybackEngine = ImagePlaybackEngine(),
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try VideoPlaybackEngine() },
        makeAudioEngine: @escaping () throws -> MPVPlaybackEngine = { try AudioPlaybackEngine() }
    ) {
        self.folderAccess = folderAccess
        self.globalSettings = globalSettings
        self.cloudFileService = cloudFileService
        self.sequences = sequences
        self.imageEngine = imageEngine
        self.makeVideoEngine = makeVideoEngine
        self.makeAudioEngine = makeAudioEngine
        imageEngine.source = self
    }

    /// Tears down the engines and releases every scoped-access session.
    func shutdown() {
        positionPersistTask?.cancel()
        positionPersistTask = nil
        cloudFileService.endMonitoring(on: .visual)
        cloudFileService.endMonitoring(on: .audio)
        videoEngine?.shutdown()
        audioEngine?.shutdown()
        imageEngine.stop()
        folderAccess.releaseAll()
        // Clear the channel bookkeeping so a reused coordinator doesn't report stale
        // active channels or a leftover suppression/overlay halt.
        liveVisualPlaylist = nil
        visualKind = nil
        liveAudioPlaylist = nil
        isSuppressed = false
        visualHaltedForOverlay = false
    }

    // MARK: - Starting playback

    /// Starts `playlist` on its channel, beginning at `file` (or its remembered /
    /// first file). Starting a visual playlist stops whichever visual playlist was
    /// playing; audio is independent.
    func play(_ playlist: Playlist, startingAt file: PlaylistFile? = nil, lifecycle: Bool = false) {
        switch playlist.mediaType {
        case .video, .image: startVisual(playlist, startingAt: file, lifecycle: lifecycle)
        case .audio: startAudio(playlist, startingAt: file, lifecycle: lifecycle)
        }
    }

    private func startVisual(_ playlist: Playlist, startingAt file: PlaylistFile?, lifecycle: Bool) {
        if let current = liveVisualPlaylist, current !== playlist { stopVisual() }
        guard let folder = folderAccess.begin(for: playlist) else { return }
        cloudFileService.beginMonitoring(playlist, folderURL: folder, on: .visual)

        let start = startFile(for: playlist, requested: file)
        liveVisualPlaylist = playlist
        visualKind = playlist.mediaType
        playlist.playbackState = .playing
        if let start { setCurrentFile(start, on: playlist) }

        switch playlist.mediaType {
        case .image:
            imageEngine.source = self
            imageEngine.fitMode = playlist.effectiveImageFitMode(globalSettings)
            // Images have no timeline, so file-position persistence doesn't apply to them.
            if let start { imageEngine.load(start, at: folder.appending(path: start.relativePath)) }
            if !isSuppressed { applySlideshow(for: playlist) }
        default:   // video
            guard let engine = ensureVideoEngine() else { return }
            loadTimeline(playlist, on: engine, folder: folder, start: start, lifecycle: lifecycle)
        }
    }

    private func startAudio(_ playlist: Playlist, startingAt file: PlaylistFile?, lifecycle: Bool) {
        if let current = liveAudioPlaylist, current !== playlist { stopAudio() }
        guard let folder = folderAccess.begin(for: playlist),
              let engine = ensureAudioEngine() else { return }
        cloudFileService.beginMonitoring(playlist, folderURL: folder, on: .audio)

        let start = startFile(for: playlist, requested: file)
        liveAudioPlaylist = playlist
        playlist.playbackState = .playing
        if let start { setCurrentFile(start, on: playlist) }
        loadTimeline(playlist, on: engine, folder: folder, start: start, lifecycle: lifecycle)
    }

    /// Loads `start` on a timeline engine (video or audio) at its resume position, honoring a
    /// standing suppression and arming the position-persist loop. Shared tail of both timeline
    /// starts; the caller has already claimed the channel and recorded the current file.
    private func loadTimeline(
        _ playlist: Playlist, on engine: MPVPlaybackEngine, folder: URL,
        start: PlaylistFile?, lifecycle: Bool
    ) {
        engine.source = self
        engine.volume = volume(for: playlist)
        if let start {
            engine.load(start, at: folder.appending(path: start.relativePath),
                        startingAt: resumePosition(for: playlist, start: start, lifecycle: lifecycle))
        }
        if isSuppressed { engine.pause() }
        startPositionPersistLoop()
    }

    // MARK: - Stopping

    /// Stops `playlist` on whichever channel it occupies and marks it Stopped.
    func stop(_ playlist: Playlist) {
        if liveVisualPlaylist === playlist { stopVisual() }
        else if liveAudioPlaylist === playlist { stopAudio() }
        else { playlist.playbackState = .stopped }
    }

    private func stopVisual() {
        guard let playlist = liveVisualPlaylist else { return }
        cloudFileService.endMonitoring(on: .visual)
        persistTimelinePosition(from: visualVideoEngine)   // capture where it stopped before the engine clears
        switch visualKind {
        case .image: imageEngine.stop()
        default: videoEngine?.stop()
        }
        liveVisualPlaylist = nil
        visualKind = nil
        visualHaltedForOverlay = false
        finalizeStop(playlist)
    }

    func stopAudio() {
        guard let playlist = liveAudioPlaylist else { return }
        cloudFileService.endMonitoring(on: .audio)
        persistTimelinePosition(from: audioEngine)   // capture where it stopped before the engine clears
        audioEngine?.stop()
        liveAudioPlaylist = nil
        finalizeStop(playlist)
    }

    /// Shared teardown tail for both channels: marks `playlist` Stopped, releases its scoped-folder
    /// session, and idles the position-persist loop once no timeline channel needs it. The caller has
    /// already stopped the engine and cleared the channel's live bookkeeping.
    private func finalizeStop(_ playlist: Playlist) {
        playlist.playbackState = .stopped
        folderAccess.end(for: playlist.id)
        stopPositionPersistLoopIfIdle()
    }

    // MARK: - Suppression (pause overlay)

    /// Halts both channels without touching their persisted states.
    func suppress() {
        guard !isSuppressed else { return }
        isSuppressed = true
        if let playlist = liveVisualPlaylist { suspend(playlist) }
        if let playlist = liveAudioPlaylist { suspend(playlist) }
    }

    /// Lifts the halt: Playing playlists resume, Paused ones stay paused.
    func unsuppress() {
        guard isSuppressed else { return }
        isSuppressed = false
        if let playlist = liveVisualPlaylist, playlist.playbackState == .playing { resume(playlist) }
        if let playlist = liveAudioPlaylist, playlist.playbackState == .playing { resume(playlist) }
    }

    // MARK: - Visual overlay halt

    func haltVisualForOverlay() {
        guard !visualHaltedForOverlay, !isSuppressed, let visual = liveVisualPlaylist else { return }
        visualHaltedForOverlay = true
        suspend(visual)
    }

    func resumeVisualForOverlay() {
        guard visualHaltedForOverlay, let visual = liveVisualPlaylist else { return }
        visualHaltedForOverlay = false
        if !isSuppressed, visual.playbackState == .playing { resume(visual) }
    }

    // MARK: - Launch reconstruction

    /// Rebuilds `playlist`'s channel at launch from its persisted state — launch's analog of
    /// lifting suppression on a reopened window. A Playing playlist resumes; a Paused one loads
    /// at its remembered file but stays paused; a Stopped one is left untouched. Loading the
    /// channel sets `.playing`, so a Paused playlist is flipped back afterward.
    func reconstruct(_ playlist: Playlist) {
        let persisted = playlist.playbackState
        guard persisted != .stopped else { return }
        play(playlist, lifecycle: true)
        if persisted == .paused { pause(playlist) }
    }

    // MARK: - Channel routing

    enum Channel { case visualVideo, visualImage, audio }

    func channel(of playlist: Playlist) -> Channel? {
        if liveVisualPlaylist === playlist { return visualKind == .image ? .visualImage : .visualVideo }
        if liveAudioPlaylist === playlist { return .audio }
        return nil
    }

    /// The mpv engine driving `playlist`'s channel — video or audio. `nil` for the image channel
    /// (no timeline) or when `playlist` isn't live. The one mapping every timeline delegator
    /// (seek, loop, volume) routes through.
    func timelineEngine(of playlist: Playlist) -> MPVPlaybackEngine? {
        switch channel(of: playlist) {
        case .visualVideo: return videoEngine
        case .audio: return audioEngine
        case .visualImage, nil: return nil
        }
    }

    /// The mpv engine backing the visual channel while it shows video; `nil` for an image channel
    /// or none. Backs the video-only read-outs (time, duration, loop).
    var visualVideoEngine: MPVPlaybackEngine? { visualKind == .video ? videoEngine : nil }

    /// Whether `playlist` currently occupies either channel. The pause/unpause transport gates on
    /// it, and the filter-change restore consults it to decide between following the live channel
    /// to the restored file and a plain reconcile.
    func isLive(_ playlist: Playlist) -> Bool { channel(of: playlist) != nil }

    /// The file the engine on `playlist`'s channel currently has loaded, or `nil` when the playlist
    /// isn't live or its channel was emptied by a prior reconcile. The filter-change restore
    /// compares this to its target so it reloads an emptied channel instead of trusting
    /// `currentFileID` (which a reconcile leaves pointing at the departed file), while still not
    /// restarting a file the engine already shows.
    func currentFile(for playlist: Playlist) -> PlaylistFile? {
        switch channel(of: playlist) {
        case .visualImage, .visualVideo: return visualCurrentFile
        case .audio: return audioCurrentFile
        case nil: return nil
        }
    }

    /// Halts a playlist's engine without changing its persisted state.
    func suspend(_ playlist: Playlist) {
        switch channel(of: playlist) {
        case .visualImage: imageEngine.stopSlideshow()
        case .visualVideo: videoEngine?.pause()
        case .audio: audioEngine?.pause()
        case nil: break
        }
    }

    /// Resumes a playlist's engine (the inverse of `suspend`).
    func resume(_ playlist: Playlist) {
        switch channel(of: playlist) {
        case .visualImage: applySlideshow(for: playlist)
        case .visualVideo: videoEngine?.play()
        case .audio: audioEngine?.play()
        case nil: break
        }
    }

    // MARK: - Helpers

    func applySlideshow(for playlist: Playlist) {
        guard playlist.preferences.slideshowEnabled else { return }
        imageEngine.startSlideshow(interval: playlist.effectiveSlideshowInterval(globalSettings))
    }

    /// The file to start at: the explicit request, else the remembered current file if it is still
    /// in the sequence, else the first file — then skipped forward to the next available file, so a
    /// missing local start never reaches an engine. A `requested` file outside the sequence — a
    /// skipped (wrong-type) file — is ignored rather than force-loaded: playback only ever walks
    /// playable files, so it starts at the first playable file instead.
    private func startFile(for playlist: Playlist, requested: PlaylistFile?) -> PlaylistFile? {
        let ids = sequences.sequence(of: playlist)
        let inSequence = { (id: PersistentIdentifier?) in id.flatMap { ids.contains($0) ? $0 : nil } }
        let requestedID = inSequence(requested?.persistentModelID)
        let currentID = inSequence(playlist.currentFileID.flatMap { playlist.modelContext?.identifier(of: $0) })
        guard let preferred = requestedID ?? currentID ?? ids.first else { return nil }
        return Self.availableFile(
            in: ids, from: preferred, forward: true, includeStart: true,
            resolve: resolveFile(in: playlist), isAvailable: isAvailable
        )
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
}
