//
//  PlaybackCoordinator+Controls.swift
//  ShuTaPla
//
//  The read-only surface the player controls and overlays render from — current
//  file, position, duration, progress — plus the loop / seek / volume delegators and
//  the slideshow and image-fit setters. None of these mutate the coordinator's channel
//  bookkeeping; they read it and forward to the live engine or the playlist's stored
//  preferences.
//

import Foundation

extension PlaybackCoordinator {

    // MARK: - Loop & seek

    /// Whether the visual channel's current file is looping (video only; images
    /// never loop). Read by the player controls and the loop hotkey's tests.
    var isVisualLooping: Bool { visualVideoEngine?.isLooping ?? false }

    /// Whether the audio channel's current file is looping.
    var isAudioLooping: Bool { audioEngine?.isLooping ?? false }

    /// Toggles looping on the file playing on `playlist`'s channel. Images have no
    /// timeline, so it's a no-op for the visual-image channel.
    func toggleLoop(_ playlist: Playlist) { timelineEngine(of: playlist)?.toggleLoop() }

    /// Seeks the file on `playlist`'s channel by `delta` seconds (the ±3s hotkeys).
    /// Video and audio only.
    func seek(_ playlist: Playlist, by delta: TimeInterval) { timelineEngine(of: playlist)?.seek(by: delta) }

    /// Seeks `playlist`'s channel to an absolute position (the scrub bar). Video/audio only.
    func seek(_ playlist: Playlist, to seconds: TimeInterval) { timelineEngine(of: playlist)?.seek(to: seconds) }

    // MARK: - Player controls surface

    /// The file the active visual channel is showing (video or image). The player
    /// controls and Visual Overlay anchor on it.
    var visualCurrentFile: PlaylistFile? {
        visualKind == .image ? imageEngine.currentFile : videoEngine?.currentFile
    }

    /// Visual playback position/duration in seconds. Images have no timeline, so both
    /// are 0 for the image channel.
    var visualCurrentTime: TimeInterval { visualVideoEngine?.currentTime ?? 0 }
    var visualDuration: TimeInterval { visualVideoEngine?.duration ?? 0 }

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

    // MARK: - Volume

    /// The playlist's persisted output level (0.0–1.0).
    func playbackVolume(for playlist: Playlist) -> Double { Double(playlist.preferences.volume) }

    /// Sets and persists `playlist`'s volume (0.0–1.0), forwarding to its live engine.
    func setVolume(_ playlist: Playlist, to value: Double) {
        let clamped = min(max(value, 0), 1)
        playlist.preferences.volume = Float(clamped)
        timelineEngine(of: playlist)?.volume = clamped * 100
    }

    // MARK: - Slideshow & fit-mode setters

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
}
