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

    private let bookmarkService: BookmarkService

    /// Global defaults a playlist's unset (`nil`) preferences fall back to — the slideshow
    /// interval and file-position persistence the coordinator resolves per playlist. Held live
    /// (not snapshotted), so editing a global default in Settings takes effect immediately.
    private let globalSettings: GlobalSettings

    /// The repeating "write the live position" loop, run while a timeline channel plays so a
    /// crash or hard quit still leaves a recent resume point. Started lazily, cancelled on shutdown.
    private var positionPersistTask: Task<Void, Never>?

    /// How often `positionPersistTask` writes the live position to disk.
    private let positionPersistInterval: TimeInterval = 5

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
        globalSettings: GlobalSettings = GlobalSettings(),
        imageEngine: ImagePlaybackEngine = ImagePlaybackEngine(),
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try VideoPlaybackEngine() },
        makeAudioEngine: @escaping () throws -> MPVPlaybackEngine = { try AudioPlaybackEngine() }
    ) {
        self.bookmarkService = bookmarkService
        self.globalSettings = globalSettings
        self.imageEngine = imageEngine
        self.makeVideoEngine = makeVideoEngine
        self.makeAudioEngine = makeAudioEngine
        imageEngine.source = self
    }

    /// Tears down the engines and releases every scoped-access session.
    func shutdown() {
        positionPersistTask?.cancel()
        positionPersistTask = nil
        videoEngine?.shutdown()
        audioEngine?.shutdown()
        imageEngine.stop()
        for bookmark in bookmarkByPlaylist.values { bookmarkService.stopAccess(to: bookmark) }
        folderURLByPlaylist.removeAll()
        bookmarkByPlaylist.removeAll()
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
        guard let folder = beginFolderAccess(for: playlist) else { return }

        let start = startFile(for: playlist, requested: file)
        let resumeAt = resumePosition(for: playlist, start: start, lifecycle: lifecycle)
        liveVisualPlaylist = playlist
        visualKind = playlist.mediaType
        playlist.playbackState = .playing
        if let start { playlist.currentFileID = start.id }

        switch playlist.mediaType {
        case .image:
            imageEngine.source = self
            imageEngine.fitMode = playlist.effectiveImageFitMode(globalSettings)
            // Images have no timeline, so file-position persistence doesn't apply to them.
            if let start { imageEngine.load(start, at: folder.appending(path: start.relativePath)) }
            if !isSuppressed { applySlideshow(for: playlist) }
        default:   // video
            guard let engine = ensureVideoEngine() else { return }
            engine.source = self
            engine.volume = volume(for: playlist)
            if let start { engine.load(start, at: folder.appending(path: start.relativePath), startingAt: resumeAt) }
            if isSuppressed { engine.pause() }
            startPositionPersistLoop()
        }
    }

    private func startAudio(_ playlist: Playlist, startingAt file: PlaylistFile?, lifecycle: Bool) {
        if let current = liveAudioPlaylist, current !== playlist { stopAudio() }
        guard let folder = beginFolderAccess(for: playlist),
              let engine = ensureAudioEngine() else { return }

        let start = startFile(for: playlist, requested: file)
        let resumeAt = resumePosition(for: playlist, start: start, lifecycle: lifecycle)
        liveAudioPlaylist = playlist
        playlist.playbackState = .playing
        if let start { playlist.currentFileID = start.id }

        engine.source = self
        engine.volume = volume(for: playlist)
        if let start { engine.load(start, at: folder.appending(path: start.relativePath), startingAt: resumeAt) }
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
        persistVisualPosition()   // capture where it stopped before the engine clears
        switch visualKind {
        case .image: imageEngine.stop()
        default: videoEngine?.stop()
        }
        playlist.playbackState = .stopped
        endFolderAccess(for: playlist.id)
        liveVisualPlaylist = nil
        visualKind = nil
        visualHaltedForOverlay = false
        stopPositionPersistLoopIfIdle()
    }

    private func stopAudio() {
        guard let playlist = liveAudioPlaylist else { return }
        persistAudioPosition()   // capture where it stopped before the engine clears
        audioEngine?.stop()
        playlist.playbackState = .stopped
        endFolderAccess(for: playlist.id)
        liveAudioPlaylist = nil
        stopPositionPersistLoopIfIdle()
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

    func togglePauseIfActive(_ playlist: Playlist) {
        playlist.playbackState == .playing ? pause(playlist) : unpause(playlist)
    }

    /// The play/pause button's full action: a playlist on the channel toggles between Playing
    /// and Paused; a stopped one (Stop removed it from the channel) starts, resuming from its
    /// remembered file. `togglePauseIfActive` alone can't start a stopped playlist — `unpause` guards on
    /// `isActive` — so the audio overlay's transport would otherwise be a dead end after Stop.
    func playOrTogglePause(_ playlist: Playlist) {
        if isActive(playlist) { togglePauseIfActive(playlist) } else { play(playlist) }
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

    // MARK: - Advance / previous

    /// Advances `playlist` to the next file in its playback sequence (wrapping).
    func next(_ playlist: Playlist) { advance(playlist, forward: true) }

    /// Steps `playlist` back to the previous file (wrapping).
    func previous(_ playlist: Playlist) { advance(playlist, forward: false) }

    private func advance(_ playlist: Playlist, forward: Bool) {
        persistPosition(on: playlist)   // save the outgoing file before it loads the next
        // Each engine reports the file it lands on through `engineDidAdvance(to:)`,
        // which syncs `currentFileID` — the same path the unattended end-of-file and
        // slideshow advances take, so there is one place that records the move.
        switch channel(of: playlist) {
        case .visualImage:
            if forward { imageEngine.advanceToNext() } else { imageEngine.returnToPrevious() }
        case .visualVideo:
            if forward { videoEngine?.advanceToNext() } else { videoEngine?.returnToPrevious() }
            settleStateAfterAdvance(playlist)
        case .audio:
            if forward { audioEngine?.advanceToNext() } else { audioEngine?.returnToPrevious() }
            settleStateAfterAdvance(playlist)
        case nil:
            break
        }
    }

    /// Loading the landed-on file auto-starts it, so reconcile the persisted state and the
    /// engine with the transport — the same `shouldBePlaying` gate `jump` uses. A channel
    /// that isn't suppressed resumes Playing (a switch from a paused channel resumes
    /// playback); while the pause overlay is up (or the playlist is otherwise paused/halted)
    /// the state is left alone and the engine re-suspended, so an arrow key can't restart
    /// playback behind the overlay or corrupt a paused playlist into Playing.
    private func settleStateAfterAdvance(_ playlist: Playlist) {
        if !isSuppressed { playlist.playbackState = .playing }
        if !shouldBePlaying(playlist) { suspend(playlist) }
    }

    // MARK: - Loop & seek

    /// Whether the visual channel's current file is looping (video only; images
    /// never loop). Read by the player controls and the loop hotkey's tests.
    var isVisualLooping: Bool {
        visualKind == .video ? (videoEngine?.isLooping ?? false) : false
    }

    /// Whether the audio channel's current file is looping.
    var isAudioLooping: Bool { audioEngine?.isLooping ?? false }

    /// Toggles looping on the file playing on `playlist`'s channel. Images have no
    /// timeline, so it's a no-op for the visual-image channel.
    func toggleLoop(_ playlist: Playlist) {
        switch channel(of: playlist) {
        case .visualVideo: videoEngine?.toggleLoop()
        case .audio: audioEngine?.toggleLoop()
        case .visualImage, nil: break
        }
    }

    /// Seeks the file on `playlist`'s channel by `delta` seconds (the ±3s hotkeys).
    /// Video and audio only.
    func seek(_ playlist: Playlist, by delta: TimeInterval) {
        switch channel(of: playlist) {
        case .visualVideo: videoEngine?.seek(by: delta)
        case .audio: audioEngine?.seek(by: delta)
        case .visualImage, nil: break
        }
    }

    // MARK: - Player controls surface

    /// The file the active visual channel is showing (video or image). The player
    /// controls and Visual Overlay anchor on it.
    var visualCurrentFile: PlaylistFile? {
        visualKind == .image ? imageEngine.currentFile : videoEngine?.currentFile
    }

    /// Visual playback position/duration in seconds. Images have no timeline, so both
    /// are 0 for the image channel.
    var visualCurrentTime: TimeInterval { visualKind == .video ? (videoEngine?.currentTime ?? 0) : 0 }
    var visualDuration: TimeInterval { visualKind == .video ? (videoEngine?.duration ?? 0) : 0 }

    /// The track the audio channel is playing, and its position/duration in seconds.
    /// The audio overlay's transport, scrubber, and tag editor anchor on these.
    var audioCurrentFile: PlaylistFile? { audioEngine?.currentFile }
    var audioCurrentTime: TimeInterval { audioEngine?.currentTime ?? 0 }
    var audioDuration: TimeInterval { audioEngine?.duration ?? 0 }

    /// Whether the audio channel has a seekable position yet (a known, positive duration). The
    /// seek bars disable themselves until it does.
    var audioIsSeekable: Bool { audioDuration > 0 }

    /// The audio channel's play position as a 0…1 fraction of its duration, clamped; 0 when no
    /// duration is known yet. The seek bars render their fill from this.
    var audioProgressFraction: Double {
        guard audioDuration > 0 else { return 0 }
        return min(max(audioCurrentTime / audioDuration, 0), 1)
    }

    /// Seeks the audio channel to `fraction` (0…1, clamped) of its duration. The one place the
    /// fraction→seconds mapping lives, shared by the inlet and overlay seek bars.
    func seekAudio(toFraction fraction: Double) {
        guard let liveAudioPlaylist else { return }
        let clamped = min(max(fraction, 0), 1)
        seek(liveAudioPlaylist, to: clamped * audioDuration)
    }

    /// Plays `file` on `playlist`'s channel right away: lifts a global pause, clears the
    /// playlist's own pause, then jumps to it. The "play this one now" intent behind a
    /// double-click in the Visual Overlay.
    func playNow(_ playlist: Playlist, startingAt file: PlaylistFile) {
        if isSuppressed { unsuppress() }
        if playlist.playbackState == .paused { unpause(playlist) }
        // Jump within the running channel; if the playlist isn't on a channel yet (never
        // started, or stopped — as when the extended audio overlay shows a restored playlist),
        // start it on its channel at this file.
        if channel(of: playlist) == nil {
            play(playlist, startingAt: file)
        } else {
            jump(playlist, to: file)
        }
    }

    /// Jumps `playlist` to a specific file without leaving it, loading it on whichever
    /// channel the playlist occupies.
    func jump(_ playlist: Playlist, to file: PlaylistFile) {
        guard let folder = folderURLByPlaylist[playlist.id] else { return }
        persistPosition(on: playlist)   // save the outgoing file before loading the new one
        let url = folder.appending(path: file.relativePath)
        playlist.currentFileID = file.id
        // A jump is a fresh entry into a file (a double-click, or a reconcile landing on a new
        // file), so it resumes mid-file only when file-position persistence is on for the playlist.
        let resumeAt = persistsPosition(playlist) ? file.lastPosition : nil
        switch channel(of: playlist) {
        case .visualImage: imageEngine.load(file, at: url)
        case .visualVideo: videoEngine?.load(file, at: url, startingAt: resumeAt)
        case .audio: audioEngine?.load(file, at: url, startingAt: resumeAt)
        case nil: break
        }
        // `load` always starts the new file playing. Re-halt it if this playlist shouldn't be
        // playing right now — globally suppressed, paused on its own, or (visual) halted for an
        // overlay — so a jump driven by a filter/deletion reconcile doesn't resume it.
        if !shouldBePlaying(playlist) { suspend(playlist) }
    }

    /// Whether `playlist` should currently be advancing, given global suppression, its own
    /// paused state, and a visual overlay halt. A `jump`'s `load` auto-starts the file, so this
    /// gates whether to immediately re-suspend it.
    private func shouldBePlaying(_ playlist: Playlist) -> Bool {
        guard playlist.playbackState == .playing, !isSuppressed else { return false }
        if liveVisualPlaylist === playlist, visualHaltedForOverlay { return false }
        return true
    }

    /// After a filter, deletion, or re-scan prune reshapes a playback sequence, advance the
    /// channel playing `playlist` off a current file that just left the sequence: jump to the
    /// first remaining file, or — when nothing remains — settle the now-empty channel. A no-op
    /// when `playlist` isn't live on a channel, and idempotent when its current file survives.
    ///
    /// The empty case diverges by channel. The visual channel stays live and empty (its engine
    /// is unloaded so a later advance/seek can't act on a departed file) so the player keeps
    /// showing its "no files" placeholder and the user can lift the filter from there; the audio
    /// channel has no such placeholder, so it stops the playlist instead (easy to restart from
    /// the audio overlay).
    func reconcile(playlistThatChanged playlist: Playlist) {
        guard let channel = channel(of: playlist) else { return }
        let current = channel == .audio ? audioCurrentFile : visualCurrentFile
        let sequence = playlist.playbackFiles
        if let current, sequence.contains(where: { $0.id == current.id }) { return }
        if let first = sequence.first {
            jump(playlist, to: first)
            return
        }
        switch channel {
        case .visualImage: imageEngine.stop()
        case .visualVideo: videoEngine?.stop()
        case .audio: stopAudio()
        }
    }

    /// Transiently halts the visual channel's advancement (slideshow timer / video)
    /// while a non-suppressing overlay edits its files, without changing persisted
    /// state or showing the pause overlay. Balanced by `resumeVisualForOverlay()`.
    private(set) var visualHaltedForOverlay = false

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

    /// Seeks `playlist`'s channel to an absolute position (the scrub bar). Video/audio only.
    func seek(_ playlist: Playlist, to seconds: TimeInterval) {
        switch channel(of: playlist) {
        case .visualVideo: videoEngine?.seek(to: seconds)
        case .audio: audioEngine?.seek(to: seconds)
        case .visualImage, nil: break
        }
    }

    /// The playlist's persisted output level (0.0–1.0).
    func playbackVolume(for playlist: Playlist) -> Double { Double(playlist.preferences.volume) }

    /// Sets and persists `playlist`'s volume (0.0–1.0), forwarding to its live engine.
    func setVolume(_ playlist: Playlist, to value: Double) {
        let clamped = min(max(value, 0), 1)
        playlist.preferences.volume = Float(clamped)
        switch channel(of: playlist) {
        case .visualVideo: videoEngine?.volume = clamped * 100
        case .audio: audioEngine?.volume = clamped * 100
        case .visualImage, nil: break
        }
    }

    /// Enables/disables and persists the slideshow for an image `playlist`, starting or
    /// stopping the live timer when it is the active visual channel and not suppressed.
    func setSlideshowEnabled(_ playlist: Playlist, _ enabled: Bool) {
        playlist.preferences.slideshowEnabled = enabled
        guard channel(of: playlist) == .visualImage else { return }
        if enabled, !isSuppressed { applySlideshow(for: playlist) }
        else { imageEngine.stopSlideshow() }
    }

    /// Sets and persists the slideshow interval for an image `playlist`, restarting a
    /// running timer at the new cadence. `nil` clears the override (the playlist falls back
    /// to the global default), applied live when it is the active image channel.
    func setSlideshowInterval(_ playlist: Playlist, _ interval: TimeInterval?) {
        playlist.preferences.slideshowInterval = interval
        guard channel(of: playlist) == .visualImage else { return }
        imageEngine.slideshowInterval = playlist.effectiveSlideshowInterval(globalSettings)
    }

    /// Sets and persists the image fit mode for an image `playlist`, applied live when it is the
    /// active image channel. `nil` clears the override (falls back to the global default).
    func setImageFitMode(_ playlist: Playlist, _ mode: ImageFitMode?) {
        playlist.preferences.imageFitMode = mode
        guard channel(of: playlist) == .visualImage else { return }
        imageEngine.fitMode = playlist.effectiveImageFitMode(globalSettings)
    }

    /// Cycles the image `playlist`'s fit mode (the `[shift]` hotkey) — Fit → Cover →
    /// Original → Fit — persisting the result as a per-playlist override.
    func cycleImageFitMode(_ playlist: Playlist) {
        setImageFitMode(playlist, playlist.effectiveImageFitMode(globalSettings).next)
    }

    // MARK: - PlaybackSource

    func fileAfter(_ current: PlaylistFile?) -> PlaylistFile? {
        guard let current, let playlist = current.playlist else { return nil }
        return playlist.playbackFiles.cyclicSuccessor { $0.id == current.id }
    }

    func fileBefore(_ current: PlaylistFile?) -> PlaylistFile? {
        guard let current, let playlist = current.playlist else { return nil }
        return playlist.playbackFiles.cyclicPredecessor { $0.id == current.id }
    }

    func url(for file: PlaylistFile) -> URL? {
        guard let playlist = file.playlist, let folder = folderURLByPlaylist[playlist.id] else { return nil }
        return folder.appending(path: file.relativePath)
    }

    func engineDidAdvance(to file: PlaylistFile) {
        file.playlist?.currentFileID = file.id
    }

    // MARK: - Channel routing

    private enum Channel { case visualVideo, visualImage, audio }

    private func channel(of playlist: Playlist) -> Channel? {
        if liveVisualPlaylist === playlist { return visualKind == .image ? .visualImage : .visualVideo }
        if liveAudioPlaylist === playlist { return .audio }
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
        imageEngine.startSlideshow(interval: playlist.effectiveSlideshowInterval(globalSettings))
    }

    /// The file to start at: the explicit request, else the remembered current
    /// file if it is still in the sequence, else the first file.
    private func startFile(for playlist: Playlist, requested: PlaylistFile?) -> PlaylistFile? {
        if let requested { return requested }
        let sequence = playlist.playbackFiles
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

    // MARK: - File-position persistence

    /// Whether `playlist` resumes mid-file: its own preference, or the global default when unset.
    private func persistsPosition(_ playlist: Playlist) -> Bool {
        playlist.effectiveFilePositionPersistence(globalSettings)
    }

    /// The position a freshly loaded file should resume from. Lifecycle reconstruction (a reopened
    /// window or a relaunch) always resumes the live channel's file from its `lastPosition`. Every
    /// other start — Play on a Stopped playlist, a switch, a double-click — resumes only while
    /// file-position persistence is on for the playlist; otherwise it begins at the start of the file.
    private func resumePosition(for playlist: Playlist, start: PlaylistFile?, lifecycle: Bool) -> TimeInterval? {
        guard let start, lifecycle || persistsPosition(playlist) else { return nil }
        return start.lastPosition
    }

    /// Writes the live position of the file playing on `playlist`'s channel back to its model,
    /// so a later launch can resume it. Routed to the right channel; a no-op for the timeline-less
    /// image channel.
    private func persistPosition(on playlist: Playlist) {
        switch channel(of: playlist) {
        case .visualVideo: persistVisualPosition()
        case .audio: persistAudioPosition()
        case .visualImage, nil: break
        }
    }

    /// Persists both live channels' positions — the periodic loop's per-tick work and the
    /// final write on stop / app teardown.
    func persistLivePositions() {
        persistVisualPosition()
        persistAudioPosition()
    }

    private func persistVisualPosition() {
        guard visualKind == .video,
              let file = videoEngine?.currentFile, let time = videoEngine?.currentTime else { return }
        file.lastPosition = time
    }

    private func persistAudioPosition() {
        guard let file = audioEngine?.currentFile, let time = audioEngine?.currentTime else { return }
        file.lastPosition = time
    }

    /// Whether a live channel has a timeline whose position the periodic loop should keep writing —
    /// any video visual channel, or the audio channel. The image channel has no timeline. The write
    /// happens regardless of the file-position setting, because lifecycle resume (a reopened window
    /// or a relaunch) restores the live channels' positions even when the setting is off.
    private var hasLiveTimelineChannel: Bool {
        if visualKind == .video { return true }
        if liveAudioPlaylist != nil { return true }
        return false
    }

    /// Starts the periodic position-write loop if it isn't already running and a live timeline
    /// channel actually needs it.
    private func startPositionPersistLoop() {
        guard positionPersistTask == nil, hasLiveTimelineChannel else { return }
        positionPersistTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.positionPersistInterval else { break }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                self.persistLivePositions()
            }
        }
    }

    /// Cancels the persist loop once no live channel needs it — every timeline channel has gone
    /// (the image channel alone has nothing to persist).
    private func stopPositionPersistLoopIfIdle() {
        guard !hasLiveTimelineChannel else { return }
        positionPersistTask?.cancel()
        positionPersistTask = nil
    }

    /// Whether the periodic position-write loop is currently running. A test seam.
    var isPositionPersistLoopRunning: Bool { positionPersistTask != nil }

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
