//
//  AppState+Confirmations.swift
//  ShuTaPla
//
//  The modal confirmations (file delete from any surface; remove-audio; playlist-wide tag
//  removal; sidebar playlist delete; saved-search delete). Each `request*` sets
//  `pendingConfirmation` to its case — the state a blocking `.alert` / `.confirmationDialog` binds
//  to; the shared `confirmConfirmation` runs whatever touches the file system as a retained,
//  self-pruning Task so its SwiftData work is owned rather than fire-and-forget. The `request*`
//  functions stay distinct because their targets differ (remove-audio eligibility, a chooser in
//  place of an alert); every file request refuses when a target is busy (`isBusy`). Everything after
//  the request is one path. A move confirms through the folder chooser instead of an alert (`requestMove` sets
//  `folderPick`), and its work runs on the same retained-task path.
//

import Foundation

extension AppState {

    // MARK: - Requests

    /// Requests confirmation to trash `files` (the Delete command and `[delete]` on every surface).
    /// Returns whether it handled the request (`request(_:failure:_:)`).
    @discardableResult
    func requestDelete(_ files: [PlaylistFile]) -> Bool {
        request(files, failure: ErrorNotice.Title.trash) { pendingConfirmation = .delete($0) }
    }

    /// Requests confirmation to remove the audio track from `files` (`[r]`, the Remove Audio
    /// command in Manager or the player overlay). Only the files `canRemoveAudio` admits
    /// are kept. Returns whether it handled the request (`request(_:failure:_:)`).
    @discardableResult
    func requestAudioStrip(_ files: [PlaylistFile]) -> Bool {
        request(files.filter(\.canRemoveAudio), failure: ErrorNotice.Title.audioStrip) {
            pendingConfirmation = .audioStrip($0)
        }
    }

    /// Raises the folder chooser to move `files` (the Move to… command). The chooser is the
    /// confirmation. Returns whether it handled the request (`request(_:failure:_:)`).
    @discardableResult
    func requestMove(_ files: [PlaylistFile]) -> Bool {
        request(files, failure: ErrorNotice.Title.move) { folderPick = .move($0.map(\.id)) }
    }

    /// Raises `present` over `files`, or refuses when any of them is busy (`isBusy`) and reports the
    /// busy count under `title`, so a confirmation always covers every file the user picked. The
    /// playlist-wide tag edits refuse a busy carrier the same way. Returns `false` only for no files.
    private func request(
        _ files: [PlaylistFile], failure title: String, _ present: ([PlaylistFile]) -> Void
    ) -> Bool {
        guard files.isNotEmpty else { return false }
        if let busy = busyNotice(files) {
            report(ErrorNotice(title: title, message: busy))
        } else {
            present(files)
        }
        return true
    }

    /// Requests confirmation to remove `tag` from every file in the managed playlist.
    func requestTagRemoval(_ tag: String) {
        pendingConfirmation = .tagRemoval(tag)
    }

    /// Requests confirmation to delete `playlist` and its files (the sidebar's Delete command).
    func requestPlaylistDelete(_ playlist: Playlist) {
        pendingConfirmation = .playlistDelete(playlist)
    }

    /// Requests confirmation to delete `search` (the expanded filter strip's button). Confirmed
    /// because the delete takes the filter with it through the cascade, so a search deleted while
    /// applied leaves the playlist unfiltered — not something to do on a stray click.
    func requestSavedSearchDelete(_ search: SavedSearch) {
        pendingConfirmation = .savedSearchDelete(search)
    }

    // MARK: - Cancel / confirm

    /// Dismisses the pending confirmation without acting on it.
    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    /// Runs the pending confirmation's destructive work as a retained, self-pruning Task,
    /// routing any failure to `errorNotice` (its title naming the family), then clears the
    /// pending state. A no-op when nothing is pending.
    func confirmConfirmation() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        switch pending {
        case .delete(let files):
            // On failure (permissions/locked) `deleteFiles` trashes nothing, so its reconcile is a
            // no-op and the surface stays on the file; surface the message rather than silently
            // advancing past an undeleted file.
            runFileOp(files.map(\.id), failure: ErrorNotice.Title.trash) { await self.deleteFiles($0) }
        case .audioStrip(let files):
            runFileOp(files.map(\.id), failure: ErrorNotice.Title.audioStrip) { await self.stripAudio(from: $0) }
        case .tagRemoval(let tag):
            guard let playlist = managedPlaylist else { return }
            runConfirmation {
                if let error = await self.removeTagAcrossPlaylist(playlist, tag: tag) {
                    self.report(ErrorNotice(title: ErrorNotice.Title.tagRemoval, message: error))
                }
            }
        case .playlistDelete(let playlist):
            runConfirmation { await self.delete(playlist) }
        case .savedSearchDelete(let search):
            // The only synchronous family: the delete is a store edit and its cascade, with no file
            // work to own — `deleteSavedSearch` persists and settles the surfaces itself.
            guard let playlist = search.playlist else { return }
            deleteSavedSearch(search, on: playlist)
        }
    }

    /// Acts on the folder chooser's outcome for `pick`, then clears the pick. A failure is reported
    /// under the pick's title.
    func completeFolderPick(_ pick: FolderPick, with result: Result<[URL], any Error>) {
        folderPick = nil
        switch (pick, result) {
        case (.addPlaylist, .success(let urls)):
            guard let url = urls.first else { return }
            Task { await importPlaylist(from: url) }
        case (.addPlaylist, .failure(let error)):
            report(.addPlaylistFailed(error.localizedDescription))
        case (.move(let ids), .success(let urls)):
            guard let folder = urls.first else { return }
            lastMoveDestination = folder
            runFileOp(ids, failure: ErrorNotice.Title.move) { await self.moveFiles($0, to: folder) }
        case (.move, .failure(let error)):
            report(ErrorNotice(title: ErrorNotice.Title.move, message: error.localizedDescription))
        }
    }

    // MARK: - Shared confirmation plumbing

    /// Whether `file` has disk work in flight (rename, tag edit, trash, move, audio removal). A
    /// second operation on it would race that work, so the requests refuse it and the operations
    /// leave it out.
    func isBusy(_ file: PlaylistFile) -> Bool {
        busyFileIDs.contains(file.id)
    }

    /// `files` without the busy ones (`isBusy`).
    func idle(_ files: [PlaylistFile]) -> [PlaylistFile] {
        files.excluding(busyFileIDs)
    }

    /// A message naming how many of `files` are busy (`isBusy`), or `nil` when none is.
    func busyNotice(_ files: [PlaylistFile]) -> String? {
        let busy = files.count(where: isBusy)
        guard busy > 0 else { return nil }
        let count = busy.pluralized(one: "1 file", many: "\(busy) files")
        return "\(count) busy. Try again when their current operation is done."
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

    /// Runs `operation` as a confirmation operation on the files of `ids` still in the store, and
    /// reports its failure under `title`. The files resolve when the Task starts: a re-scan can
    /// prune one while the chooser is open, or in the turn before the Task starts, and a read of a
    /// pruned row traps. A view starts its file edits here for the same reason, and for the report:
    /// the `HotkeyRouter` holds the keyboard only for a modal it can see on `AppState`.
    func runFileOp(
        _ ids: [UUID], failure title: String, _ operation: @escaping ([PlaylistFile]) async -> String?
    ) {
        runConfirmation {
            let files = self.modelContext.files(withIDs: ids)
            guard files.isNotEmpty, let error = await operation(files) else { return }
            self.report(ErrorNotice(title: title, message: error))
        }
    }

    /// Runs the playlist-wide Replace of `oldTag` by `entry` on the retained confirmation path, as
    /// the tag removal runs, and reports its failure.
    func commitTagReplace(_ oldTag: String, with entry: String, on playlist: Playlist) {
        runConfirmation {
            if let error = await self.replaceTagAcrossPlaylist(playlist, oldTag, with: entry) {
                self.report(ErrorNotice(title: ErrorNotice.Title.tagChange, message: error))
            }
        }
    }

    /// Cancels any in-flight confirmation operations.
    func cancelConfirmationTasks() {
        for task in confirmationTasks.values { task.cancel() }
        confirmationTasks.removeAll()
    }
}
