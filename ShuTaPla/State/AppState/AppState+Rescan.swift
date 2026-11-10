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
    /// kicks off a background re-scan to pick up files added or removed on disk. A playlist being
    /// deleted is refused: the delete released it before it waits for the playlist's file ops.
    func manage(_ playlist: Playlist) {
        guard !playlistWork.isDeleting(playlist.id) else { return }
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
           sequences.isMember(currentID, of: playlist) {
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
        guard !playlistWork.isDeleting(playlist.id) else { return }
        let isNewSelection = coordinator.liveVisualPlaylist !== playlist
        manage(playlist)
        if isNewSelection { coordinator.play(playlist) }
    }

    /// The audio overlay's play-on-select: loads `playlist` into the audio channel slot and
    /// re-reads its folder (every click — the same automatic Update the Manager does). A
    /// genuinely new selection also starts it playing; re-selecting the loaded one re-scans and
    /// re-centers without restarting playback. Independent of the managed slot — the overlay
    /// drives the audio channel, not the Manager. A playlist being deleted is refused, as in `manage`.
    func playOnAudioChannel(_ playlist: Playlist) {
        guard !playlistWork.isDeleting(playlist.id) else { return }
        let isNewSelection = audioChannelPlaylist !== playlist
        remember(playlist)   // audioChannelPlaylist = playlist
        if isNewSelection { coordinator.play(playlist) }
        audioScrollToken += 1   // re-center the overlay file list on the current track
        rescan(playlist)
    }

    /// Renames a playlist; an empty or whitespace-only name is rejected.
    func rename(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isNotEmpty else { return }
        playlist.name = trimmed
        notePlaylistsChanged()   // the row's label
    }

    /// Deletes a playlist and its files, clearing any active/selected reference to
    /// it and compacting the remaining sort orders in its section. The selection
    /// clears immediately; the files are then removed in batches (yielding between
    /// each) so a large playlist's cleanup keeps the UI responsive and its row can
    /// show a spinner until it disappears. The removal waits for the playlist's file ops in
    /// flight: their disk work (a long move, a remux) can't stop midway, and their tails read the
    /// rows and the playlist. It also waits for the cancelled re-scan: one past its commit decision
    /// still applies to the playlist (`PlaylistWorkGate`). The slots and the channel are released
    /// before the wait, so only a listing can hand a caller the playlist meanwhile: every function
    /// that takes one into a slot or a channel refuses it.
    func delete(_ playlist: Playlist) async {
        let id = playlist.id
        guard playlistWork.beginDelete(id) else { return }
        // Release the playback channel first: a playing audio playlist (which runs even in
        // Manager mode) would otherwise leave the engine on files about to be deleted, and
        // its next advance would dereference a destroyed model.
        coordinator.stop(playlist)
        if managedPlaylist === playlist { exitReviewModes(); managedPlaylist = nil }
        let mediaType = playlist.mediaType
        // A playlist can only sit in its own type's remembered slot, so clearing that one slot
        // covers every reference the delete must drop.
        if rememberedPlaylist(for: mediaType) === playlist { setRemembered(nil, for: mediaType) }

        await playlistWork.waitForWork(on: id)
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
        playlistWork.endDelete(id)
        compactSortOrder(for: mediaType)
        persistAndRefresh()
        notePlaylistsChanged()   // the row is gone and the section renumbered
    }

    /// Reorders the playlists of one section. `ordered` is the section's current
    /// order; the move is applied and the new positions written to `sortOrder`.
    func reorder(_ ordered: [Playlist], fromOffsets: IndexSet, toOffset: Int) {
        var copy = ordered
        copy.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, playlist) in copy.enumerated() {
            playlist.sortOrder = index
        }
        notePlaylistsChanged()   // the section's order
    }

    /// Cancels the running background re-scans — the only cancellable Manager operation. A new
    /// playlist's tag derive keeps running: nothing re-derives a playlist whose derive rolled back.
    /// Returns whether something was in flight (the Manager `[esc]` hotkey consumes the key either
    /// way).
    @discardableResult
    func cancelInProgressOperation() -> Bool {
        guard rescanCounts.isNotEmpty else { return false }
        playlistWork.cancel(rescanCounts.keys)
        updateTask = nil
        return true
    }

    // MARK: - Background re-scan

    /// Re-reads `playlist`'s folder on disk in the background — the automatic Update, the reason
    /// there's no dedicated control: re-clicking the open playlist re-scans and re-centers.
    /// Supersedes any in-flight re-scan of the *same* playlist so rapid clicks don't pile up,
    /// while leaving a different playlist's scan running. A playlist with a file op in flight
    /// defers the re-scan until the op ends (`PlaylistWorkGate`).
    private func rescan(_ playlist: Playlist) {
        guard playlistWork.requestScan(playlist.id) else { return }
        trackBackgroundTask(for: playlist.id) { await self.update(playlist) }
    }

    /// Runs `work` as the playlist's tracked background task (`PlaylistWorkGate.track`), which a
    /// delete or a file op cancels and awaits, and as `updateTask` so tests can await it.
    func trackBackgroundTask(for playlistID: UUID, _ work: @escaping () async -> Void) {
        updateTask = playlistWork.track(playlistID, work)
    }

    /// Opens `playlist`'s folder for a file op's disk work, apart from the playlist's re-scan. A
    /// re-scan that lists the folder before the op and reconciles after it would undo the op: bring
    /// back a trashed or moved row, or put a renamed row back under its old name. So the in-flight
    /// re-scan is cancelled (its reconcile rolls back) and awaited first, and a re-scan requested
    /// during the op runs once the playlist's last op ends (`PlaylistWorkGate`). A playlist being
    /// deleted starts no op (returns `nil`).
    func withDiskOpAccess<T>(to playlist: Playlist, perform body: (URL) async -> T) async -> T? {
        guard await playlistWork.beginOp(playlist.id) else { return nil }
        defer { if playlistWork.endOp(playlist.id) { rescan(playlist) } }
        return await withFolderAccess(to: playlist, perform: body)
    }

    /// Runs `body` under a one-shot session on `playlist`'s folder. A folder that can't be found
    /// reports `folderNotFound` and returns `nil`.
    func withFolderAccess<T>(to playlist: Playlist, perform body: (URL) -> T) -> T? {
        reportingLostFolder(of: playlist, folderAccess.withAccess(to: playlist, perform: body))
    }

    /// The `async` form of `withFolderAccess(to:perform:)`.
    func withFolderAccess<T>(to playlist: Playlist, perform body: (URL) async -> T) async -> T? {
        reportingLostFolder(of: playlist, await folderAccess.withAccess(to: playlist, perform: body))
    }

    private func reportingLostFolder<T>(of playlist: Playlist, _ result: T?) -> T? {
        if result == nil { report(.folderNotFound(playlist.name)) }
        return result
    }

    /// Re-scans a playlist's folder and reconciles its files against what's now on disk: prunes
    /// the missing ones, appends the new ones, and re-derives every current file's filename tags
    /// onto the index the filters query. The reconcile — the O(N) derive/diff/write/orphan-sweep —
    /// runs on the background `scanActor`; the main actor only finishes applying the result.
    /// A rescan failure (e.g. a stale bookmark) is silent — the file list stays as it was — but a
    /// failed background save surfaces through `errorNotice`, like the main-actor save path.
    func update(_ playlist: Playlist) async {
        guard !Task.isCancelled else { return }
        let id = playlist.id
        rescanCounts[id, default: 0] += 1
        defer { rescanCounts.decrementCount(forKey: id) }

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
    /// surfaces through `errorNotice`; a no-op or cancelled/rolled-back reconcile leaves the store and
    /// UI untouched.
    func deriveInBackground(_ playlist: Playlist, from current: [ScannedFile]) async {
        // Where playback stands, read before the reconcile can prune the row out from under it —
        // afterwards the engine's current file may be a destroyed model whose `sortOrder` can no
        // longer be read. A prune never renumbers the survivors (the reconcile only appends, from
        // their max `sortOrder`), so this stays a valid lower bound for the landing below.
        let resumeFrom = coordinator.currentFile(for: playlist)?.sortOrder
        // No pre-apply cancellation guard: the actor makes the commit decision before its save
        // (rolling back and reporting `.unchanged` if cancelled there), so a committed result is
        // always applied here. Gating the apply on cancellation could strand a commit — store
        // changed, but the version never bumped and pruned-file references left dangling.
        let result = await scanActor.reconcile(current, playlistID: playlist.id)
        if let message = result.saveErrorMessage {
            // The background save threw and rolled back — nothing committed. Surface it through the
            // same app-root alert the main-actor save path uses; do not apply (the store is intact).
            report(.saveFailed(message))
            return
        }
        guard result.changed else { return }
        applyScanResult(result, to: playlist, resumingFrom: resumeFrom)
    }

    /// Finishes a background reconcile on the main actor: the O(1) tail the actor can't do across
    /// contexts. The background context already saved the files, `tagFrequency`, and swept orphan
    /// tags (this context does no save — a main save would write its held pre-scan `files` back over
    /// the store, dropping the actor's writes). Here we drop any pending UI reference to a pruned
    /// file, refresh the held playlist so its attributes and `files` reflect the committed write,
    /// bump the version so the store-side file lists re-fetch, and advance either channel off a
    /// dropped playing file.
    private func applyScanResult(_ result: ScanReconcileResult, to playlist: Playlist, resumingFrom sortOrder: Int?) {
        forgetRemovedFiles(Set(result.removedFileIDs))

        // The actor committed on its own context, which doesn't merge into this held playlist; a
        // fetch refaults it in place so the tag UI (which reads `playlist.tagFrequency`) and any
        // `files` walk see the new state. The version bump re-derives the store-side file lists.
        //
        // Acknowledged race: between the actor's background commit (in `deriveInBackground`) and this
        // bump, a main-actor read of `sequences.sequence(of:)` serves the pre-scan memo — one stale
        // frame. It's self-correcting: this bump re-derives every list and `coordinator.reconcile`
        // advances the channels off any dropped file, so the store and the surfaces reconverge the
        // moment this hop runs. No membership decision is finalized from the stale window.
        modelContext.refreshFromStore(playlist)
        sequences.bump()
        notePlaylistsChanged()   // the reconcile pruned/appended files, so the row's count moved
        // A re-scan can drop either channel's playing file; advance off it just like a delete
        // does, so neither engine holds a file that's no longer in the playlist — and from where
        // playback stood, since the sequence only lost files rather than becoming a different set.
        coordinator.reconcile(playlistThatChanged: playlist, resumingFrom: sortOrder)
    }

    /// Renumbers a section's `sortOrder` values to 0..<count after a deletion.
    private func compactSortOrder(for mediaType: MediaType) {
        for (index, playlist) in modelContext.playlists(ofType: mediaType).enumerated() {
            playlist.sortOrder = index
        }
    }
}
