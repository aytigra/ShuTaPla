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
        return Self.availableFile(
            in: playlist.playbackFiles, from: current, forward: true, includeStart: false, isAvailable: isAvailable
        )
    }

    func fileBefore(_ current: PlaylistFile?) -> PlaylistFile? {
        guard let current, let playlist = current.playlist else { return nil }
        return Self.availableFile(
            in: playlist.playbackFiles, from: current, forward: false, includeStart: false, isAvailable: isAvailable
        )
    }

    /// Whether `file` is a valid load target. An evicted file is (the engine placeholders it until
    /// the bytes arrive), and a present local file is; only a `.local` file gone from disk before a
    /// rescan pruned it is not. An unresolvable folder can't be checked, so the file isn't treated as
    /// missing — the engine's own load simply no-ops.
    func isAvailable(_ file: PlaylistFile) -> Bool {
        guard file.cloudStatus == .local, let url = url(for: file) else { return true }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func url(for file: PlaylistFile) -> URL? {
        guard let playlist = file.playlist, let folder = folderAccess.url(for: playlist.id) else { return nil }
        return folder.appending(path: file.relativePath)
    }

    func requestDownload(_ file: PlaylistFile) {
        guard let url = url(for: file) else { return }
        cloudFileService.requestDownload(at: url)
    }

    func engineDidAdvance(to file: PlaylistFile) {
        if let playlist = file.playlist { setCurrentFile(file, on: playlist) }
    }

    /// Records `file` as `playlist`'s current resume cursor and mirrors its shuffle position into
    /// the active filter's slot — the single point every natural file switch (Play, jump, an
    /// engine-reported advance) routes through, so the outgoing filter's slot stays current. Each
    /// switch also prefetches the files just ahead, so an evicted one is already arriving by the
    /// time the cursor reaches it.
    func setCurrentFile(_ file: PlaylistFile, on playlist: Playlist) {
        playlist.currentFileID = file.id
        playlist.captureResumePosition(file.sortOrder)
        for target in Self.prefetchTargets(
            after: file, in: playlist.playbackFiles, count: AppConstants.cloudPrefetchCount
        ) {
            requestDownload(target)
        }
    }

    /// The prefetch horizon after `current`: the next `count` files in playback order — wrapping
    /// past the end the way playback does — that aren't already on disk. Never includes `current`,
    /// and never repeats a file when the sequence is shorter than `count + 1`. Pure, so the
    /// selection is unit-tested apart from the coordinator and its download side effect.
    /// Walking `sequence` in playback order (wrapping) from `start`, the first file `isAvailable`
    /// accepts — the shared "next available" resolution that skips a missing local file before any
    /// engine touches it. `forward` picks the direction; `includeStart` treats `start` itself as the
    /// first candidate (resolving a jump / start target) rather than stepping past it (advance /
    /// previous). Pure over the injected predicate, so the walk is unit-tested apart from the disk
    /// existence check the coordinator supplies. `nil` when no file in the sequence is available.
    static func availableFile(
        in sequence: [PlaylistFile], from start: PlaylistFile, forward: Bool,
        includeStart: Bool, isAvailable: (PlaylistFile) -> Bool
    ) -> PlaylistFile? {
        let count = sequence.count
        guard count > 0, let index = sequence.firstIndex(where: { $0.id == start.id }) else { return nil }
        for offset in (includeStart ? 0 : 1)..<count {
            let position = forward ? (index + offset) % count : ((index - offset) % count + count) % count
            let candidate = sequence[position]
            if isAvailable(candidate) { return candidate }
        }
        return nil
    }

    static func prefetchTargets(
        after current: PlaylistFile, in sequence: [PlaylistFile], count: Int
    ) -> [PlaylistFile] {
        guard count > 0, sequence.count > 1,
              let index = sequence.firstIndex(where: { $0.id == current.id }) else { return [] }
        let horizon = min(count, sequence.count - 1)
        return (1...horizon)
            .map { sequence[(index + $0) % sequence.count] }
            .filter { $0.cloudStatus != .local }
    }
}
