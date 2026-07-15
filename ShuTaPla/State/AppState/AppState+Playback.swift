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

    /// The managed playlist's ordered file identifiers under its effective filter — the Manager
    /// center list/gallery, resolved row-by-row as it scrolls. A transient review mode swaps the
    /// derivation: find-duplicates derives the duplicate grouping, skipped-review lists the skipped
    /// files. Routing all three through the same memoization keeps it a live derivation, so a delete
    /// re-derives it and collapses a resolved group rather than going stale.
    var managerFileIDs: [PersistentIdentifier] {
        guard let playlist = managedPlaylist else { return [] }
        if duplicateSearchActive { return sequences.duplicateSequence(of: playlist) }
        if skippedReviewActive { return sequences.skippedSequence(of: playlist) }
        return sequences.sequence(of: playlist)
    }

    /// Enters the find-duplicates mode of the Manager center for `playlist` (making it managed if
    /// it isn't) — the buried tool raised from `PlaylistSettingsView`.
    func findDuplicates(in playlist: Playlist) {
        if managedPlaylist !== playlist { setManaged(playlist) }
        // Flush fingerprints merged onto records while scrolling (relying on autosave) before the
        // mode's `duplicateSequence` fetch, which ignores pending changes — otherwise a just-viewed
        // pair would be invisible to the grouping.
        persistAndRefresh()
        setDuplicateSearch(true)
    }

    /// Enters the skipped-review mode of the Manager center for `playlist` (already the managed
    /// playlist — the center notice bar's "N skipped").
    func reviewSkipped(in playlist: Playlist) {
        if managedPlaylist !== playlist { setManaged(playlist) }
        setSkippedReview(true)
    }

    /// Enters or leaves the find-duplicates review mode, exiting skipped-review when it enters.
    func setDuplicateSearch(_ active: Bool) {
        setReviewMode(duplicates: active, skipped: active ? false : skippedReviewActive)
    }

    /// Enters or leaves the skipped-review mode, exiting find-duplicates when it enters.
    func setSkippedReview(_ active: Bool) {
        setReviewMode(duplicates: active ? false : duplicateSearchActive, skipped: active)
    }

    /// Whether the Manager center is showing one of the transient review surfaces (a duplicate
    /// grouping or the wrong-type skipped files) rather than the real playback sequence — the
    /// condition every play affordance gates on, since neither surface is playable.
    var inReviewMode: Bool { duplicateSearchActive || skippedReviewActive }

    /// Leaves whichever review mode is active — the exit a filter edit, a managed-playlist switch,
    /// and a scope switch share.
    func exitReviewModes() {
        setReviewMode(duplicates: false, skipped: false)
    }

    /// Applies the two mutually-exclusive review-mode flags together. A no-op when neither changes;
    /// otherwise clears the selection (made against the outgoing sequence) and bumps the sequence
    /// version so `managerFileIDs` re-derives through the swapped mode. A delete only bumps the
    /// version, so it recomputes *within* the mode and collapses a resolved group instead of exiting.
    private func setReviewMode(duplicates: Bool, skipped: Bool) {
        guard duplicates != duplicateSearchActive || skipped != skippedReviewActive else { return }
        duplicateSearchActive = duplicates
        skippedReviewActive = skipped
        managerSelection = []
        sequences.bump()
    }

    /// The token the Manager center file list re-centers on (a re-select or scope switch).
    var managerScrollToken: Int { scrollSelectionToken }

    /// The single Manager play chokepoint — the center double-click and the `[enter]` selection
    /// (`playSelectedFile`) both funnel through it: it gates on review mode and hands off to
    /// `startPlayback`, which routes a visual playlist into the fullscreen player and an audio one
    /// onto its channel. A no-op in either review mode — the surfaced set isn't a real playback
    /// sequence, so preview (not play) is the way to inspect a file there; returns whether it
    /// started, so the `[enter]` key only consumes when it acts.
    @discardableResult
    func playFromManager(of playlist: Playlist, startingAt file: PlaylistFile) -> Bool {
        guard !inReviewMode else { return false }
        startPlayback(of: playlist, startingAt: file)
        return true
    }

    // MARK: - Channel-derived surfaces

    /// The audio channel playlist's file identifiers under its effective filter — the audio
    /// overlay's list, resolved row-by-row as it scrolls. The service filter set in Manager still
    /// applies (e.g. Untagged narrows the channel to its untagged tracks).
    var audioChannelFileIDs: [PersistentIdentifier] {
        guard let playlist = audioChannelPlaylist else { return [] }
        return sequences.sequence(of: playlist)
    }

    /// The visual channel playlist's file identifiers — the Visual Overlay's list, resolved
    /// row-by-row.
    var visualChannelFileIDs: [PersistentIdentifier] {
        guard let playlist = coordinator.liveVisualPlaylist else { return [] }
        return sequences.sequence(of: playlist)
    }

    /// The audio channel's current track — the audio overlay's analog of `managerSelection`.
    /// Resolved from the playlist's persisted `currentFileID`, not the live engine, so it
    /// survives Stop: a stopped audio playlist still shows (and resumes from) where it left off.
    /// `nil` when the remembered file is filtered out of the sequence.
    var currentAudioFile: PlaylistFile? {
        _ = sequences.version
        return currentFile(of: audioChannelPlaylist)
    }

    /// The visual channel's current file — the Visual Overlay's analog of
    /// `currentAudioFile`. Resolved from the playing playlist's persisted `currentFileID`, not
    /// the live engine, so it's available synchronously when the overlay's file list re-centers
    /// after a playlist switch (the video engine reports its current file asynchronously).
    /// `nil` when the remembered file is filtered out of the sequence.
    var currentVisualFile: PlaylistFile? {
        _ = sequences.version
        return currentFile(of: coordinator.liveVisualPlaylist)
    }

    /// A live channel's current/last file, resolved from its playlist's persisted `currentFileID`
    /// and returned only if it survives the playlist's effective filter — the shared core of
    /// `currentAudioFile`/`currentVisualFile`. Resolves only that one file (no whole-sequence
    /// materialization).
    private func currentFile(of playlist: Playlist?) -> PlaylistFile? {
        guard let playlist, let id = playlist.currentFileID else { return nil }
        return modelContext.sequenceMember(id, of: playlist)
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

    /// Plays the Manager file-list selection (the `[enter]` hotkey): resolves the earliest selected
    /// file and starts it through `playFromManager`, so the review-mode gate and audio/visual
    /// routing are shared with the double-click. Returns whether it started, so the key only
    /// consumes when it acts (no selection to play, or a review mode blocks it → false).
    @discardableResult
    func playSelectedFile() -> Bool {
        guard let playlist = managedPlaylist else { return false }
        // The earliest selected row in display order: intersect the (small) selection with the
        // ordered identifier sequence, then resolve only that one file.
        let selected = Set(selectedManagerFiles().map(\.persistentModelID))
        guard let pid = managerFileIDs.first(where: { selected.contains($0) }),
              let file = file(for: pid) else { return false }
        return playFromManager(of: playlist, startingAt: file)
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
        guard ids.isNotEmpty else { return false }

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
