//
//  AppState+Rescan.swift
//  ShuTaPla
//
//  Making a playlist the Manager selection (or a channel's live playlist) and the automatic
//  Update that follows: the per-playlist background re-scan, its reconcile/apply tail, and the
//  playlist-level operations that share this bookkeeping — rename, delete, reorder.
//

import Foundation
import SwiftData

extension AppState {

    // MARK: - Select / activate

    /// Makes `playlist` the Manager selection, activates it for its channel, and
    /// kicks off a background re-scan to pick up files added or removed on disk.
    func manage(_ playlist: Playlist) {
        let isNewSelection = managedPlaylist !== playlist
        if isNewSelection {
            managerSelection = []
            // Selecting a different audio playlist swaps the audio channel slot; only one audio
            // playlist is ever live, so release the channel to keep a background one from playing
            // on behind the new selection. (Visual playback is stopped while browsing in Manager.)
            if playlist.mediaType == .audio, let live = coordinator.liveAudioPlaylist, live !== playlist {
                coordinator.stop(live)
            }
        }
        setManaged(playlist)   // managed slot + scope, restoring the persisted filter at once
        // Highlight where playback will resume and scroll the list to it. Re-selecting the managed
        // playlist snaps the highlight back to the playing file — the one way to do so without
        // leaving it. Skipped when the resume file is filtered out (or none has played yet).
        if let currentID = playlist.currentFileID,
           displaySequenceContains(currentID, of: playlist) {
            managerSelection = [currentID]
        }
        scrollSelectionToken += 1   // re-center even if the selection didn't change
        rescan(playlist)
    }

    /// The Visual Overlay's analog of `playOnAudioChannel(_:)`: switches the
    /// visual channel to `playlist` through `manage(_:)` — restoring its filter, re-reading its
    /// folder (every click, the automatic Update), and re-centering the file list — and starts a
    /// genuinely new selection playing. Re-selecting the playing playlist re-scans and re-centers
    /// without restarting it.
    func playOnVisualChannel(_ playlist: Playlist) {
        let isNewSelection = coordinator.liveVisualPlaylist !== playlist
        manage(playlist)
        if isNewSelection { coordinator.play(playlist) }
    }

    /// The audio overlay's play-on-select: loads `playlist` into the audio channel slot and
    /// re-reads its folder (every click — the same automatic Update the Manager does). A
    /// genuinely new selection also starts it playing; re-selecting the loaded one re-scans and
    /// re-centers without restarting playback. Independent of the managed slot — the overlay
    /// drives the audio channel, not the Manager.
    func playOnAudioChannel(_ playlist: Playlist) {
        let isNewSelection = audioChannelPlaylist !== playlist
        remember(playlist)   // audioChannelPlaylist = playlist
        if isNewSelection { coordinator.play(playlist) }
        audioScrollToken += 1   // re-center the overlay file list on the current track
        rescan(playlist)
    }

    /// Renames a playlist; an empty or whitespace-only name is rejected.
    func rename(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
    }

    /// Deletes a playlist and its files, clearing any active/selected reference to
    /// it and compacting the remaining sort orders in its section. The selection
    /// clears immediately; the files are then removed in batches (yielding between
    /// each) so a large playlist's cleanup keeps the UI responsive and its row can
    /// show a spinner until it disappears.
    func delete(_ playlist: Playlist) async {
        updateTasks[playlist.id]?.cancel()
        updateTasks[playlist.id] = nil
        // Release the playback channel first: a playing audio playlist (which runs even in
        // Manager mode) would otherwise leave the engine on files about to be deleted, and
        // its next advance would dereference a destroyed model.
        coordinator.stop(playlist)
        if managedPlaylist === playlist { setDuplicateSearch(false); managedPlaylist = nil }
        let mediaType = playlist.mediaType
        // A playlist can only sit in its own type's remembered slot, so clearing that one slot
        // covers every reference the delete must drop.
        if rememberedPlaylist(for: mediaType) === playlist { setRemembered(nil, for: mediaType) }
        let id = playlist.id

        deletingPlaylistIDs.insert(id)
        let files = Array(playlist.files)
        var start = 0
        let batchSize = 200
        while start < files.count {
            let end = min(start + batchSize, files.count)
            for file in files[start..<end] {
                file.playlist = nil  // detach so the cascade doesn't re-walk them
                modelContext.delete(file)
            }
            start = end
            await Task.yield()
        }
        modelContext.delete(playlist)
        deletingPlaylistIDs.remove(id)
        compactSortOrder(for: mediaType)
        persistAndRefresh()
    }

    /// Reorders the playlists of one section. `ordered` is the section's current
    /// order; the move is applied and the new positions written to `sortOrder`.
    func reorder(_ ordered: [Playlist], fromOffsets: IndexSet, toOffset: Int) {
        var copy = ordered
        copy.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, playlist) in copy.enumerated() {
            playlist.sortOrder = index
        }
    }

    /// Cancels a running background re-scan — the only cancellable Manager operation.
    /// Returns whether something was in flight (the Manager `[esc]` hotkey consumes the
    /// key either way).
    @discardableResult
    func cancelInProgressOperation() -> Bool {
        guard !busyPlaylistIDs.isEmpty else { return false }
        for task in updateTasks.values { task.cancel() }
        updateTasks.removeAll()
        updateTask = nil
        return true
    }

    // MARK: - Background re-scan

    /// Re-reads `playlist`'s folder on disk in the background — the automatic Update, the reason
    /// there's no dedicated control: re-clicking the open playlist re-scans and re-centers.
    /// Supersedes any in-flight re-scan of the *same* playlist so rapid clicks don't pile up,
    /// while leaving a different playlist's scan running. The spawned task is also remembered as
    /// `updateTask` so a delete can cancel it and tests can await it.
    private func rescan(_ playlist: Playlist) {
        trackBackgroundTask(for: playlist.id) { await self.update(playlist) }
    }

    /// Launches `work` as the playlist's tracked background task: cancels any in-flight one for the
    /// same playlist (so rapid re-selection, or a create followed by a rescan, doesn't pile up),
    /// records it per-playlist so a delete can cancel it, and as `updateTask` so tests can await it.
    func trackBackgroundTask(for playlistID: UUID, _ work: @escaping () async -> Void) {
        updateTasks[playlistID]?.cancel()
        let task = Task { await work() }
        updateTasks[playlistID] = task
        updateTask = task
    }

    /// Re-scans a playlist's folder and reconciles its files against what's now on disk: prunes
    /// the missing ones, appends the new ones, and re-derives every current file's filename tags
    /// onto the index the filters query. The reconcile — the O(N) derive/diff/write/orphan-sweep —
    /// runs on the background `scanActor`; the main actor only finishes applying the result.
    /// A rescan failure (e.g. a stale bookmark) is silent — the file list stays as it was — but a
    /// failed background save surfaces through `saveError`, like the main-actor save path.
    func update(_ playlist: Playlist) async {
        guard !Task.isCancelled else { return }
        busyPlaylistIDs.insert(playlist.id)
        defer { busyPlaylistIDs.remove(playlist.id) }

        // Commit a refreshed bookmark before handing off, so the main context holds no pending
        // edit the background reconcile is unaware of and the actor's fetch sees the new bookmark.
        if folderAccess.refreshStaleBookmark(for: playlist) { try? modelContext.save() }

        let current: [ScannedFile]
        do {
            current = try await fileSystem.rescan(bookmark: playlist.folderBookmark)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await deriveInBackground(playlist, from: current)
    }

    /// Reconciles `playlist` against `current` on the background `scanActor` and applies a committed
    /// result on the main actor — the derivation half shared by Update (which re-reads the folder
    /// first) and creation (which already holds the scanned files). A failed background save
    /// surfaces through `saveError`; a no-op or cancelled/rolled-back reconcile leaves the store and
    /// UI untouched.
    func deriveInBackground(_ playlist: Playlist, from current: [ScannedFile]) async {
        // No pre-apply cancellation guard: the actor makes the commit decision before its save
        // (rolling back and reporting `.unchanged` if cancelled there), so a committed result is
        // always applied here. Gating the apply on cancellation could strand a commit — store
        // changed, but the version never bumped and pruned-file references left dangling.
        let result = await scanActor.reconcile(current, playlistID: playlist.id)
        if let message = result.saveErrorMessage {
            // The background save threw and rolled back — nothing committed. Surface it through the
            // same app-root alert the main-actor save path uses; do not apply (the store is intact).
            saveError = Self.saveErrorText(message)
            return
        }
        guard result.changed else { return }
        applyScanResult(result, to: playlist)
    }

    /// Finishes a background reconcile on the main actor: the O(1) tail the actor can't do across
    /// contexts. The background context already saved the files, `tagFrequency`, and swept orphan
    /// tags (this context does no save — a main save would write its held pre-scan `files` back over
    /// the store, dropping the actor's writes). Here we drop any pending UI reference to a pruned
    /// file, refresh the held playlist so its attributes and `files` reflect the committed write,
    /// bump the version so the store-side file lists re-fetch, and advance either channel off a
    /// dropped playing file.
    private func applyScanResult(_ result: ScanReconcileResult, to playlist: Playlist) {
        let removedIDs = Set(result.removedFileIDs)
        // Drop pending references to pruned files so a confirmation raised over one the re-scan
        // removed can't act on (and dereference) a destroyed model when the user confirms.
        pendingConfirmation = pendingConfirmation?.pruning(removedFileIDs: removedIDs)
        managerSelection.subtract(removedIDs)

        // The actor committed on its own context, which doesn't merge into this held playlist; a
        // fetch refaults it in place so the tag UI (which reads `playlist.tagFrequency`) and any
        // `files` walk see the new state. The version bump re-derives the store-side file lists.
        modelContext.refreshFromStore(playlist)
        sequenceVersion &+= 1
        // A re-scan can drop either channel's playing file; advance off it just like a delete
        // does, so neither engine holds a file that's no longer in the playlist.
        coordinator.reconcile(playlistThatChanged: playlist)
    }

    /// Renumbers a section's `sortOrder` values to 0..<count after a deletion.
    private func compactSortOrder(for mediaType: MediaType) {
        for (index, playlist) in modelContext.playlists(ofType: mediaType).enumerated() {
            playlist.sortOrder = index
        }
    }
}
