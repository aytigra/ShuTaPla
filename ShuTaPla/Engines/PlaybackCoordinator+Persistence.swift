//
//  PlaybackCoordinator+Persistence.swift
//  ShuTaPla
//
//  File-position persistence — resolving where a freshly loaded file should resume,
//  writing live positions back to their files, and the periodic loop that keeps a
//  recent resume point on disk while a timeline channel plays — together with the
//  `PlaybackSource` conformance the engines call to walk the sequence and load URLs.
//

import Foundation

extension PlaybackCoordinator {

    // MARK: - File-position persistence

    /// Whether `playlist` resumes mid-file: its own preference, or the global default when unset.
    func persistsPosition(_ playlist: Playlist) -> Bool {
        playlist.effectiveFilePositionPersistence(globalSettings)
    }

    /// The position a freshly loaded file should resume from. Lifecycle reconstruction (a reopened
    /// window or a relaunch) always resumes the live channel's file from its `lastPosition`. Every
    /// other start — Play on a Stopped playlist, a switch, a double-click — resumes only while
    /// file-position persistence is on for the playlist; otherwise it begins at the start of the file.
    func resumePosition(for playlist: Playlist, start: PlaylistFile?, lifecycle: Bool) -> TimeInterval? {
        guard let start, lifecycle || persistsPosition(playlist) else { return nil }
        return start.lastPosition
    }

    /// Writes `engine`'s live position back to the file it has loaded, so a later launch can resume
    /// there. A no-op when the engine is absent or has no loaded file (so the timeline-less image
    /// channel, whose `timelineEngine` is `nil`, is skipped). Callers pass the channel's engine via
    /// `timelineEngine(of:)`, `visualVideoEngine`, or `audioEngine`.
    func persistTimelinePosition(from engine: MPVPlaybackEngine?) {
        guard let file = engine?.currentFile, let time = engine?.currentTime else { return }
        file.lastPosition = time
    }

    /// Persists both live channels' positions — the periodic loop's per-tick work and the
    /// final write on stop / app teardown.
    func persistLivePositions() {
        persistTimelinePosition(from: visualVideoEngine)
        persistTimelinePosition(from: audioEngine)
    }

    /// Whether a live channel has a timeline whose position the periodic loop should keep writing —
    /// any video visual channel, or the audio channel. The image channel has no timeline. The write
    /// happens regardless of the file-position setting, because lifecycle resume (a reopened window
    /// or a relaunch) restores the live channels' positions even when the setting is off.
    var hasLiveTimelineChannel: Bool {
        if visualKind == .video { return true }
        if liveAudioPlaylist != nil { return true }
        return false
    }

    /// Starts the periodic position-write loop if it isn't already running and a live timeline
    /// channel actually needs it.
    func startPositionPersistLoop() {
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
    func stopPositionPersistLoopIfIdle() {
        guard !hasLiveTimelineChannel else { return }
        positionPersistTask?.cancel()
        positionPersistTask = nil
    }

    /// Whether the periodic position-write loop is currently running. A test seam.
    var isPositionPersistLoopRunning: Bool { positionPersistTask != nil }

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
        guard let playlist = file.playlist, let folder = folderAccess.url(for: playlist.id) else { return nil }
        return folder.appending(path: file.relativePath)
    }

    func engineDidAdvance(to file: PlaylistFile) {
        if let playlist = file.playlist { setCurrentFile(file, on: playlist) }
    }

    /// Records `file` as `playlist`'s current resume cursor and mirrors its shuffle position into
    /// the active filter's slot — the single point every natural file switch (Play, jump, an
    /// engine-reported advance) routes through, so the outgoing filter's slot stays current.
    func setCurrentFile(_ file: PlaylistFile, on playlist: Playlist) {
        playlist.currentFileID = file.id
        playlist.captureResumePosition(file.sortOrder)
    }
}
