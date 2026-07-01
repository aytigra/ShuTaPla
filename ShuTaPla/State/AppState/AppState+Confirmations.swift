//
//  AppState+Confirmations.swift
//  ShuTaPla
//
//  The request / cancel / confirm triples behind the modal confirmations (Manager, Player, and
//  extended-overlay audio delete; remove-audio; playlist-wide tag removal). Each `request` sets the
//  pending state a blocking `.alert` binds to; `confirm` runs the destructive work as a retained,
//  self-pruning Task so its SwiftData work is owned rather than fire-and-forget.
//

import Foundation

extension AppState {

    // MARK: - Manager delete

    /// Requests confirmation to trash the current file-list selection (Manager
    /// `[delete]`). Returns whether there was anything selected to delete.
    @discardableResult
    func requestDeleteSelectedFiles() -> Bool {
        let files = managerSelectionFiles()
        guard !files.isEmpty else { return false }
        pendingManagerDelete = files
        return true
    }

    /// Requests confirmation to trash a specific set of Manager files (a file row's
    /// Delete command). Routes through AppState so `pendingManagerDelete` stays state
    /// it owns and prunes when a re-scan removes a referenced file.
    func requestManagerDelete(_ files: [PlaylistFile]) {
        pendingManagerDelete = files
    }

    /// Dismisses the Manager trash confirmation without trashing anything.
    func cancelManagerDelete() {
        pendingManagerDelete = []
    }

    /// Trashes the files pending in the Manager confirmation, surfacing any failure
    /// through `managerDeleteError`.
    func confirmManagerDelete() {
        let targets = pendingManagerDelete
        pendingManagerDelete = []
        performDelete(targets) { self.managerDeleteError = $0 }
    }

    // MARK: - Player delete

    /// Requests confirmation to trash the file currently playing on the visual channel
    /// (Player `[delete]`). Returns whether there was a file to delete.
    @discardableResult
    func requestDeletePlayingFile() -> Bool {
        guard let file = coordinator.visualCurrentFile else { return false }
        playerDeleteCandidate = file
        return true
    }

    /// Requests confirmation to remove the audio from the video currently playing on the
    /// visual channel (Player `[r]`). Video-only — an image or audio file has no audio track
    /// to strip. Returns whether there was a video to act on. The trash analog is
    /// `requestDeletePlayingFile`; the per-file overlay/menu analog is `requestAudioStrip`.
    @discardableResult
    func requestStripPlayingFile() -> Bool {
        guard coordinator.liveVisualPlaylist?.mediaType == .video,
              let file = coordinator.visualCurrentFile else { return false }
        requestAudioStrip([file])
        return true
    }

    /// Requests confirmation to trash a specific file from the Visual Overlay.
    /// Routes through AppState so `playerDeleteCandidate` stays state it owns and
    /// prunes when a re-scan removes the file.
    func requestPlayerDelete(_ file: PlaylistFile) {
        playerDeleteCandidate = file
    }

    /// Dismisses the Player delete confirmation without trashing anything.
    func cancelPlayerDelete() {
        playerDeleteCandidate = nil
    }

    /// Trashes the file pending in the Player delete confirmation and advances the
    /// player to the next still-available file in the playlist.
    func confirmPlayerDelete() {
        guard let file = playerDeleteCandidate else { return }
        playerDeleteCandidate = nil
        performDelete([file]) { self.playerDeleteError = $0 }
    }

    // MARK: - Extended-overlay audio delete

    /// Requests confirmation to trash the audio channel's current track (the extended
    /// overlay's `[delete]`, when audio holds key context). Returns whether there was a
    /// track to delete. The visual `[delete]` analog is `requestDeletePlayingFile`.
    @discardableResult
    func requestDeletePlayingAudioFile() -> Bool {
        guard let file = currentAudioFile else { return false }
        audioDeleteCandidate = file
        return true
    }

    /// Requests confirmation to trash an audio track from the extended overlay.
    func requestAudioDelete(_ file: PlaylistFile) {
        audioDeleteCandidate = file
    }

    /// Dismisses the extended-overlay trash confirmation without trashing anything.
    func cancelAudioDelete() {
        audioDeleteCandidate = nil
    }

    /// Trashes the track pending in the extended-overlay confirmation, surfacing any
    /// failure through `audioDeleteError`.
    func confirmAudioDelete() {
        guard let file = audioDeleteCandidate else { return }
        audioDeleteCandidate = nil
        performDelete([file]) { self.audioDeleteError = $0 }
    }

    // MARK: - Remove audio

    /// Requests confirmation to remove the audio track from a video-row's selection
    /// (its Remove Audio command, in Manager or the player overlay). Routes through
    /// AppState so `pendingAudioStrip` stays state it owns and prunes when a re-scan
    /// removes a referenced file.
    func requestAudioStrip(_ files: [PlaylistFile]) {
        pendingAudioStrip = files
    }

    /// Dismisses the remove-audio confirmation without changing anything.
    func cancelAudioStrip() {
        pendingAudioStrip = []
    }

    /// Removes the audio from the videos pending in the confirmation, surfacing any
    /// failure through `audioStripError`.
    func confirmAudioStrip() {
        let targets = pendingAudioStrip
        pendingAudioStrip = []
        guard !targets.isEmpty else { return }
        runConfirmation { if let error = await self.stripAudio(from: targets) { self.audioStripError = error } }
    }

    // MARK: - Playlist-wide tag removal

    /// Dismisses the playlist-wide tag-removal confirmation without removing anything.
    func cancelTagRemoval() {
        pendingTagRemoval = nil
    }

    /// Removes the pending tag from every file in the selected playlist, surfacing any
    /// failure through `tagRemovalError`.
    func confirmTagRemoval() {
        guard let tag = pendingTagRemoval, let playlist = managedPlaylist else {
            pendingTagRemoval = nil
            return
        }
        pendingTagRemoval = nil
        runConfirmation { if let error = await self.removeTagAcrossPlaylist(playlist, tag: tag) { self.tagRemovalError = error } }
    }

    // MARK: - Shared confirmation plumbing

    /// Trashes `files` as a retained confirmation task — `deleteFiles` advances any live channel
    /// off them — routing the first failure message to `report`. The one place the trash + the
    /// post-delete error handling lives, shared by the Manager, Player, and audio confirmations.
    private func performDelete(_ files: [PlaylistFile], onError report: @escaping (String) -> Void) {
        guard !files.isEmpty else { return }
        // On failure (permissions/locked) `deleteFiles` trashes nothing, so its reconcile is a
        // no-op and the surface stays on the file; surface the message rather than silently
        // advancing past an undeleted file.
        runConfirmation { if let error = await self.deleteFiles(files) { report(error) } }
    }

    /// Runs a confirmation operation as a retained, self-pruning Task so the SwiftData work
    /// it performs is owned (cancellable, awaitable) rather than fire-and-forget.
    private func runConfirmation(_ operation: @escaping () async -> Void) {
        let token = UUID()
        confirmationTasks[token] = Task {
            await operation()
            confirmationTasks[token] = nil
        }
    }

    /// Cancels any in-flight confirmation operations.
    func cancelConfirmationTasks() {
        for task in confirmationTasks.values { task.cancel() }
        confirmationTasks.removeAll()
    }
}
