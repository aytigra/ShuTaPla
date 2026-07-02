//
//  AppState+Playback.swift
//  ShuTaPla
//
//  Starting playback from the Manager, exiting the player, and the channel-derived surfaces the
//  overlays bind to: each channel's store-side file-identifier list and its current file (resolved
//  from the persisted cursor, so it survives Stop), plus the Manager center list and its 2-D
//  keyboard navigation.
//

import Foundation
import SwiftData

extension AppState {

    // MARK: - Manager center list

    /// The managed playlist's display-ordered file identifiers under its effective filter — the
    /// Manager center list/gallery, resolved row-by-row as it scrolls.
    var managerFileIDs: [PersistentIdentifier] {
        _ = sequenceVersion
        return managedPlaylist.map { modelContext.displaySequence(of: $0) } ?? []
    }

    /// The token the Manager center file list re-centers on (a re-select or scope switch).
    var managerScrollToken: Int { scrollSelectionToken }

    /// A double-click in the Manager center: a visual playlist enters the fullscreen player at
    /// the file; an audio playlist starts the audio channel there, staying in Manager.
    func playFromManager(of playlist: Playlist, startingAt file: PlaylistFile) {
        if playlist.mediaType == .audio {
            coordinator.play(playlist, startingAt: file)
        } else {
            startPlayback(of: playlist, startingAt: file)
        }
    }

    // MARK: - Channel-derived surfaces

    /// The audio channel playlist's file identifiers under its effective filter — the audio
    /// overlay's list, resolved row-by-row as it scrolls. This is the *playback* sequence, so
    /// skipped tracks never appear: the audio overlay is a transport list (no triage toggles),
    /// and a track the engine won't play has no place in it. Under the Skipped filter the list
    /// is therefore empty. The service filter set in Manager still applies (e.g. Untagged
    /// narrows the channel to its untagged playable tracks).
    var audioChannelFileIDs: [PersistentIdentifier] {
        _ = sequenceVersion
        return audioChannelPlaylist.map { modelContext.playbackSequence(of: $0) } ?? []
    }

    /// The visual channel playlist's display-ordered file identifiers — the Visual
    /// Overlay's list, resolved row-by-row. This is the *display* sequence (it keeps skipped
    /// files under the Skipped filter), because the Visual Overlay is an editing surface
    /// where skipped rows are triaged and un-skipped.
    var visualChannelFileIDs: [PersistentIdentifier] {
        _ = sequenceVersion
        return coordinator.liveVisualPlaylist.map { modelContext.displaySequence(of: $0) } ?? []
    }

    /// The audio channel's current track — the audio overlay's analog of `managerSelection`.
    /// Resolved from the playlist's persisted `currentFileID`, not the live engine, so it
    /// survives Stop: a stopped audio playlist still shows (and resumes from) where it left off.
    /// `nil` when the remembered file is filtered out of the playback view.
    var currentAudioFile: PlaylistFile? {
        _ = sequenceVersion
        return currentFile(of: audioChannelPlaylist, view: .playback)
    }

    /// The visual channel's current file — the Visual Overlay's analog of
    /// `currentAudioFile`. Resolved from the playing playlist's persisted `currentFileID`, not
    /// the live engine, so it's available synchronously when the overlay's file list re-centers
    /// after a playlist switch (the video engine reports its current file asynchronously).
    /// `nil` when the remembered file is filtered out of the display view.
    var currentVisualFile: PlaylistFile? {
        _ = sequenceVersion
        return currentFile(of: coordinator.liveVisualPlaylist, view: .display)
    }

    /// Which effective-filter view a channel's current file is tested against: the audio overlay
    /// is a transport list (playback view, no skipped tracks); the Visual Overlay is an
    /// editing surface (display view, keeps skipped rows under the Skipped filter).
    private enum SequenceView { case display, playback }

    /// A live channel's current/last file, resolved from its playlist's persisted `currentFileID`
    /// and returned only if it survives the playlist's effective filter — the shared core of
    /// `currentAudioFile`/`currentVisualFile`. Resolves only that one file (no whole-sequence
    /// materialization).
    private func currentFile(of playlist: Playlist?, view: SequenceView) -> PlaylistFile? {
        guard let playlist, let id = playlist.currentFileID else { return nil }
        switch view {
        case .display: return modelContext.displayMember(id, of: playlist)
        case .playback: return modelContext.playbackMember(id, of: playlist)
        }
    }

    // MARK: - Starting & exiting playback

    /// The audio inlet's Play when no audio playlist is active: start the first audio playlist
    /// if any exist, otherwise raise the add-folder flow to create one. (Once a playlist is
    /// active, the inlet shows the transport instead, whose Play continues that playlist.)
    func startFirstAudioPlaylistOrAdd() {
        if let first = modelContext.playlists(ofType: .audio).first {
            startPlayback(of: first)
        } else {
            isImportingPlaylist = true
        }
    }

    /// Starts a playlist playing through the coordinator. A visual playlist takes the window
    /// into Player mode and becomes the managed playlist; an audio playlist plays on its
    /// independent channel without changing mode or the managed (visual) slot.
    func startPlayback(of playlist: Playlist, startingAt file: PlaylistFile? = nil) {
        // Audio is an independent channel driven from its overlay/inlet, so starting it must
        // not disturb the managed visual playlist or the scope.
        if playlist.mediaType == .audio {
            remember(playlist)   // audioChannelPlaylist = playlist
            coordinator.play(playlist, startingAt: file)
            return
        }
        if managedPlaylist !== playlist { managerSelection = [] }
        setManaged(playlist)
        coordinator.play(playlist, startingAt: file)
        mode = .player
    }

    /// Plays the Manager file-list selection (the `[enter]` hotkey): begins playback of the
    /// managed playlist starting at the first selected file. Returns whether there was a
    /// selection to play, so the key only consumes when it acts.
    @discardableResult
    func playSelectedFile() -> Bool {
        guard let playlist = managedPlaylist else { return false }
        // The earliest selected row in display order: intersect the (small) selection with the
        // ordered identifier sequence, then resolve only that one file.
        let selected = Set(selectedManagerFiles().map(\.persistentModelID))
        guard let pid = managerFileIDs.first(where: { selected.contains($0) }),
              let file = file(for: pid) else { return false }
        startPlayback(of: playlist, startingAt: file)
        return true
    }

    /// Stops the visual playlist and returns the window to Manager mode (the pause overlay's
    /// Stop, the `[s]`/`[delete]`-after exits, and the Back control). Stopping the transient
    /// visual channel ejects its playlist into the managed slot, switching scope to its type.
    func stopAndExitPlayer() {
        let visual = coordinator.liveVisualPlaylist
        // Remember the file that was on screen so Manager reopens with it selected and
        // scrolled into view, rather than at the top.
        let lastFileID = coordinator.visualCurrentFile?.id
        if let visual { coordinator.stop(visual) }
        coordinator.unsuppress()
        cancelConfirmation()   // dismiss any player-context confirmation left open on exit
        if let visual { setManaged(visual) }
        if let lastFileID { managerSelection = [lastFileID] }
        scrollSelectionToken += 1
        mode = .manager
    }

    // MARK: - Grid navigation

    /// Moves the Manager file-list selection one step in `direction` through `managerFiles`,
    /// collapsing any multi-selection to a single row. In list mode it is a vertical 1-D walk;
    /// in gallery mode left/right step by one and up/down step by a full row. Returns whether
    /// the key was consumed (so no system beep).
    @discardableResult
    func moveFileSelection(_ direction: MoveDirection) -> Bool {
        let ids = managerFileIDs
        guard !ids.isEmpty else { return false }

        let gallery = managedPlaylist?.preferences.viewMode == .gallery
        let columns = gallery ? max(1, fileGridColumns) : 1
        let step: Int
        switch direction {
        case .up: step = -columns
        case .down: step = columns
        case .left: step = gallery ? -1 : 0      // no horizontal axis in the list
        case .right: step = gallery ? 1 : 0
        }

        // A horizontal key in the single-column list has no axis to move along; consume
        // it (so it never beeps) without disturbing the selection.
        guard step != 0 else { return true }

        // Map the (small) selection to its positions in the identifier sequence; only the
        // target row is resolved to a model.
        let selectedPIDs = Set(selectedManagerFiles().map(\.persistentModelID))
        let selected = ids.indices.filter { selectedPIDs.contains(ids[$0]) }
        let targetIndex: Int
        if let edge = (step >= 0 ? selected.max() : selected.min()) {
            let candidate = edge + step
            // Stay within bounds; ignore a move that would fall off the grid (still
            // consumed, so the key never beeps).
            guard candidate >= 0, candidate < ids.count else { return true }
            targetIndex = candidate
        } else {
            targetIndex = step >= 0 ? 0 : ids.count - 1
        }
        if let file = file(for: ids[targetIndex]) {
            managerSelection = [file.id]
        }
        return true
    }
}
