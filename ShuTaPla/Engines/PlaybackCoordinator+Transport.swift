//
//  PlaybackCoordinator+Transport.swift
//  ShuTaPla
//
//  In-channel transport: per-playlist pause/unpause, stepping through the playback
//  sequence, and jumping to a specific file (directly, on a "play this now", or to
//  reconcile a sequence that changed underneath). These read the channel bookkeeping
//  and drive the live engine and the playlist's own persisted state; they never claim
//  or release a channel — that is the core's lifecycle.
//

import Foundation

extension PlaybackCoordinator {

    // MARK: - Per-playlist pause / unpause

    /// Pauses a playing playlist, recording its own Paused state. A no-op while
    /// suppressed defers the engine pause to suppression, but the state still flips.
    func pause(_ playlist: Playlist) {
        guard isLive(playlist) else { return }
        playlist.playbackState = .paused
        if !isSuppressed { suspend(playlist) }
    }

    /// Resumes a paused playlist, restoring its Playing state.
    func unpause(_ playlist: Playlist) {
        guard isLive(playlist) else { return }
        playlist.playbackState = .playing
        if !isSuppressed { resume(playlist) }
    }

    func togglePauseIfActive(_ playlist: Playlist) {
        playlist.playbackState == .playing ? pause(playlist) : unpause(playlist)
    }

    /// The play/pause button's full action: a playlist on the channel toggles between Playing
    /// and Paused; a stopped one (Stop removed it from the channel) starts, resuming from its
    /// remembered file. `togglePauseIfActive` alone can't start a stopped playlist — `unpause` guards on
    /// `isLive` — so the audio overlay's transport would otherwise be a dead end after Stop.
    func playOrTogglePause(_ playlist: Playlist) {
        if isLive(playlist) { togglePauseIfActive(playlist) } else { play(playlist) }
    }

    // MARK: - Advance / previous

    /// Advances `playlist` to the next file in its playback sequence (wrapping).
    func next(_ playlist: Playlist) { advance(playlist, forward: true) }

    /// Steps `playlist` back to the previous file (wrapping).
    func previous(_ playlist: Playlist) { advance(playlist, forward: false) }

    private func advance(_ playlist: Playlist, forward: Bool) {
        persistTimelinePosition(from: timelineEngine(of: playlist))   // save the outgoing file before it loads the next
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

    // MARK: - Jump / play-now / reconcile

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
        guard let folder = folderAccess.url(for: playlist.id) else { return }
        // Skip a missing local target to the next available file before any engine loads it.
        let target = Self.availableFile(
            in: playlist.playbackFiles, from: file, forward: true, includeStart: true, isAvailable: isAvailable
        ) ?? file
        persistTimelinePosition(from: timelineEngine(of: playlist))   // save the outgoing file before loading the new one
        let url = folder.appending(path: target.relativePath)
        setCurrentFile(target, on: playlist)
        // A jump is a fresh entry into a file (a double-click, or a reconcile landing on a new
        // file), so it resumes mid-file only when file-position persistence is on for the playlist.
        let resumeAt = persistsPosition(playlist) ? target.lastPosition : nil
        switch channel(of: playlist) {
        case .visualImage: imageEngine.load(target, at: url)
        case .visualVideo: videoEngine?.load(target, at: url, startingAt: resumeAt)
        case .audio: audioEngine?.load(target, at: url, startingAt: resumeAt)
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
}
