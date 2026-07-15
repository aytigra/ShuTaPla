//
//  AppState+Confirmations.swift
//  ShuTaPla
//
//  The modal confirmations (Manager, Player, and extended-overlay audio delete; remove-audio;
//  playlist-wide tag removal; sidebar playlist delete). Each `request*` sets `pendingConfirmation`
//  to its case — the state a blocking `.alert` / `.confirmationDialog` binds to; the shared
//  `confirmConfirmation` runs the destructive work as a retained, self-pruning Task so its
//  SwiftData work is owned rather than fire-and-forget. The `request*` functions stay distinct
//  because their guards differ (video-only strip, current-track reads); everything after the
//  request is one path.
//

import Foundation

extension AppState {

    // MARK: - Requests

    /// Requests confirmation to trash the current file-list selection (Manager
    /// `[delete]`). Returns whether there was anything selected to delete.
    @discardableResult
    func requestDeleteSelectedFiles() -> Bool {
        let files = managerSelectionFiles()
        guard files.isNotEmpty else { return false }
        pendingConfirmation = .managerDelete(files)
        return true
    }

    /// Requests confirmation to trash a specific set of Manager files (a file row's Delete command).
    func requestManagerDelete(_ files: [PlaylistFile]) {
        pendingConfirmation = .managerDelete(files)
    }

    /// Requests confirmation to trash the file currently playing on the visual channel
    /// (Player `[delete]`). Returns whether there was a file to delete.
    @discardableResult
    func requestDeletePlayingFile() -> Bool {
        guard let file = coordinator.visualCurrentFile else { return false }
        pendingConfirmation = .playerDelete(file)
        return true
    }

    /// Requests confirmation to trash a specific file from the Visual Overlay.
    func requestPlayerDelete(_ file: PlaylistFile) {
        pendingConfirmation = .playerDelete(file)
    }

    /// Requests confirmation to trash the audio channel's current track (the extended
    /// overlay's `[delete]`, when audio holds key context). Returns whether there was a
    /// track to delete. The visual `[delete]` analog is `requestDeletePlayingFile`.
    @discardableResult
    func requestDeletePlayingAudioFile() -> Bool {
        guard let file = currentAudioFile else { return false }
        pendingConfirmation = .audioDelete(file)
        return true
    }

    /// Requests confirmation to trash an audio track from the extended overlay.
    func requestAudioDelete(_ file: PlaylistFile) {
        pendingConfirmation = .audioDelete(file)
    }

    /// Requests confirmation to remove the audio from the video currently playing on the
    /// visual channel (Player `[r]`). Video-only — an image or audio file has no audio track
    /// to strip. Returns whether there was a video to act on.
    @discardableResult
    func requestStripPlayingFile() -> Bool {
        guard coordinator.liveVisualPlaylist?.mediaType == .video,
              let file = coordinator.visualCurrentFile else { return false }
        requestAudioStrip([file])
        return true
    }

    /// Requests confirmation to remove the audio track from a video-row's selection (its
    /// Remove Audio command, in Manager or the player overlay).
    func requestAudioStrip(_ files: [PlaylistFile]) {
        pendingConfirmation = .audioStrip(files)
    }

    /// Requests confirmation to remove `tag` from every file in the managed playlist.
    func requestTagRemoval(_ tag: String) {
        pendingConfirmation = .tagRemoval(tag)
    }

    /// Requests confirmation to delete `playlist` and its files (the sidebar's Delete command).
    func requestPlaylistDelete(_ playlist: Playlist) {
        pendingConfirmation = .playlistDelete(playlist)
    }

    // MARK: - Cancel / confirm

    /// Dismisses the pending confirmation without acting on it.
    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    /// Runs the pending confirmation's destructive work as a retained, self-pruning Task,
    /// routing any failure to `confirmationError` (its title naming the family), then clears the
    /// pending state. A no-op when nothing is pending.
    func confirmConfirmation() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        switch pending {
        case .managerDelete(let files): performDelete(files)
        case .playerDelete(let file): performDelete([file])
        case .audioDelete(let file): performDelete([file])
        case .audioStrip(let files):
            guard files.isNotEmpty else { return }
            runConfirmation {
                if let error = await self.stripAudio(from: files) {
                    self.confirmationError = ConfirmationError(title: "Couldn't remove audio", message: error)
                }
            }
        case .tagRemoval(let tag):
            guard let playlist = managedPlaylist else { return }
            runConfirmation {
                if let error = await self.removeTagAcrossPlaylist(playlist, tag: tag) {
                    self.confirmationError = ConfirmationError(title: "Couldn't remove tag", message: error)
                }
            }
        case .playlistDelete(let playlist):
            runConfirmation { await self.delete(playlist) }
        }
    }

    // MARK: - Shared confirmation plumbing

    /// Trashes `files` as a retained confirmation task — `deleteFiles` advances any live channel
    /// off them — surfacing the first failure as a "Couldn't move to Trash" error. Shared by the
    /// Manager, Player, and audio delete confirmations.
    private func performDelete(_ files: [PlaylistFile]) {
        guard files.isNotEmpty else { return }
        // On failure (permissions/locked) `deleteFiles` trashes nothing, so its reconcile is a
        // no-op and the surface stays on the file; surface the message rather than silently
        // advancing past an undeleted file.
        runConfirmation {
            if let error = await self.deleteFiles(files) {
                self.confirmationError = ConfirmationError(title: "Couldn't move to Trash", message: error)
            }
        }
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
