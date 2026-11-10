//
//  AppState+FileOps.swift
//  ShuTaPla
//
//  The file-level edits that touch the disk through one-shot scoped folder access: rename,
//  trash, move, remove-audio, reshuffle, reveal-in-Finder, and the tag edits (which rename files on
//  disk too). `applyRename`/`applyTagRenames` are the shared disk-rename core the tag edits reuse.
//

import Foundation
import SwiftData
import AppKit

extension AppState {

    // MARK: - File operations

    /// Renames a file on disk, then updates the model (name, relative path, and
    /// re-parsed tags). Returns a user-facing message on failure; `nil` on success, for the file's own
    /// name (a rename field commits on every click-away), when the re-scan has removed the file, or
    /// when the op does not start (folder access not obtained, the playlist is being deleted).
    func renameFile(_ file: PlaylistFile, to newName: String) async -> String? {
        guard newName.trimmingCharacters(in: .whitespacesAndNewlines) != file.fileName else { return nil }
        guard file.playlist != nil else { return "This file isn't in a playlist." }
        return await withFileOp([file]) { _, playlist, folderURL, _ in
            let before = file.tagFrequencyNames
            if let error = await applyRename(file, to: newName, in: folderURL) { return error }
            modelContext.applyTagFrequencyDelta(to: playlist, before: before, after: file.tagFrequencyNames)
            persistAndRefresh()
            return nil
        }
    }

    /// Renames a file from a file list — the Manager's or either player overlay's — through
    /// `runFileOp`, so a file the re-scan prunes first is left out.
    func commitRename(of id: UUID, to newName: String) {
        runFileOp([id], failure: ErrorNotice.Title.rename) { await self.renameFile($0[0], to: newName) }
    }

    /// Renames one file on disk and mirrors the result onto the model, with the
    /// playlist folder's scoped access already open. Returns a message on failure.
    /// Callers apply the resulting tag-frequency delta per file (the rename re-parses `tags`).
    private func applyRename(_ file: PlaylistFile, to newName: String, in folderURL: URL) async -> String? {
        let newURL: URL
        do {
            newURL = try await fileSystem.renameFile(
                at: folderURL.appending(path: file.relativePath),
                to: newName
            )
        } catch let error as FileSystemError {
            return error.userMessage
        } catch {
            return "Rename failed."
        }

        let finalName = newURL.lastPathComponent
        let parent = (file.relativePath as NSString).deletingLastPathComponent
        file.fileName = finalName
        file.relativePath = parent.isEmpty ? finalName : "\(parent)/\(finalName)"
        let (tags, status) = TagParser.fields(for: finalName)
        file.tags = modelContext.tags(named: tags)
        file.taggingStatus = status
        return nil
    }

    /// Moves files to the Trash (best effort) and removes the trashed ones from
    /// the playlist. Returns a message when some files couldn't be trashed, with the first cause.
    func deleteFiles(_ files: [PlaylistFile]) async -> String? {
        await withFileOp(files) { files, playlist, folderURL, _ in
            let (urls, byURL) = diskURLs(of: files, in: folderURL)
            let result = await fileSystem.trashFiles(urls)
            removeFromPlaylist(result.succeeded.compactMap { byURL[$0] }, playlist)
            return batchFailure(result, couldnt: "be moved to the Trash")
        }
    }

    /// Moves files into `folder` (best effort) and removes the moved ones from the playlist, as a
    /// delete does — wherever `folder` is. A destination in the playlist folder gets the file back
    /// as a new row on the next re-scan. Files already in `folder` are left alone. Returns a
    /// message when some files couldn't be moved, with the first cause.
    func moveFiles(_ files: [PlaylistFile], to folder: URL) async -> String? {
        await withFileOp(files) { files, playlist, folderURL, _ in
            await folder.withSecurityScopedAccess { folder in
                let (urls, byURL) = diskURLs(of: files, in: folderURL)
                let result = await fileSystem.moveFiles(urls, to: folder)
                removeFromPlaylist(result.succeeded.compactMap { byURL[$0] }, playlist)
                return batchFailure(result, couldnt: "be moved")
            }
        }
    }

    /// Runs a file op's disk work on the idle files of `files`. It marks them busy (`isBusy`), so no
    /// other file op reaches them while the work is in flight, and opens their playlist's folder
    /// (`withDiskOpAccess`). Each op claims here, where its disk work starts, not only at request
    /// time: a confirmation or an inline rename can run after its files became busy. The returned
    /// message reports the busy files it skipped (`busyNotice`) after the op's own message.
    ///
    /// `body` gets the claimed files that still exist in the store. The re-scan that
    /// `withDiskOpAccess` awaits can prune a claimed row, and a read of a pruned row's persisted
    /// property traps. `body` does not run when no claimed file remains. Its `release` ends the
    /// busy mark of one file before the op ends. The busy marks are ended by the ids kept at claim
    /// time, never read from a row after the await, and only for the files this op claimed, so the
    /// op never clears a busy mark that another op holds.
    ///
    /// Busy marks are per row. Two playlists over one folder hold two rows for one file, and their
    /// ops can reach that file together, as Finder can. Each op is best-effort per file: the later
    /// one fails or acts on what it finds, and the original stays in place or in the Trash.
    private func withFileOp(
        _ files: [PlaylistFile],
        perform body: (
            _ files: [PlaylistFile], _ playlist: Playlist, _ folderURL: URL, _ release: (PlaylistFile) -> Void
        ) async -> String?
    ) async -> String? {
        let skipped = busyNotice(files)
        let claimed = idle(files)
        guard let playlist = claimed.first?.playlist else { return skipped }
        let ids = claimed.map(\.id)
        var held = Set(ids)
        busyFileIDs.formUnion(held)
        // A strip can release every file early; a write of an unchanged set still re-renders the rows.
        defer { if held.isNotEmpty { busyFileIDs.subtract(held) } }
        let error = await withDiskOpAccess(to: playlist) { folderURL -> String? in
            let live = modelContext.files(withIDs: ids)
            guard live.isNotEmpty else { return nil }
            return await body(live, playlist, folderURL) { file in
                held.remove(file.id)
                busyFileIDs.remove(file.id)
            }
        } ?? nil
        let messages = [error, skipped].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// The on-disk URL of each of `files`, in their order (a move into one folder keeps the first of
    /// two files of one name), and the map from a batch result's URLs back to rows.
    private func diskURLs(
        of files: [PlaylistFile], in folderURL: URL
    ) -> (urls: [URL], files: [URL: PlaylistFile]) {
        let pairs = files.map { (folderURL.appending(path: $0.relativePath), $0) }
        return (pairs.map(\.0), Dictionary(pairs) { first, _ in first })
    }

    /// Removes rows whose files were trashed or moved, and moves playback off them.
    private func removeFromPlaylist(_ files: [PlaylistFile], _ playlist: Playlist) {
        guard files.isNotEmpty else { return }
        // Where playback stands, read in the window between the disk op and the removal: playback
        // runs on through the disk op and can advance onto a file it takes, so an earlier read
        // would land behind where the channel actually is. Read it before the rows go, too — once
        // the removal is saved the engine's current file is an invalidated instance whose
        // `sortOrder` can no longer be read.
        let resumeFrom = coordinator.currentFile(for: playlist)?.sortOrder
        forgetRemovedFiles(Set(files.map(\.id)))
        for file in files {
            modelContext.applyTagFrequencyDelta(to: playlist, before: file.tagFrequencyNames, after: [])
            file.playlist = nil
            modelContext.delete(file)
        }
        persistAndRefresh()
        notePlaylistsChanged()   // the row's file count
        // Advance whichever channel was playing this playlist off a removed track, so the engine
        // never holds a file that's no longer in the playlist. Covers every delete and move entry
        // point (Manager list, Visual Overlay, audio overlay) in one place. Playback continues from
        // where it stood — removing the file on screen must not rewind the session to the head of
        // the sequence.
        coordinator.reconcile(playlistThatChanged: playlist, resumingFrom: resumeFrom)
    }

    /// Drops every pending UI reference to removed files, so a confirmation, the Manager selection,
    /// or a preview raised over one can't act on (and dereference) a deleted model. A move pick holds
    /// ids and resolves them on completion (`FolderPick.move`), so it needs no prune.
    /// Writes only a value that holds a removed file: every write invalidates the views that read it.
    /// It reads `id` of the removed rows, so it runs before this context deletes them or refaults
    /// their playlist; after that only `persistentModelID` is a safe read (`existsInStore`).
    func forgetRemovedFiles(_ ids: Set<UUID>) {
        if let pendingConfirmation, pendingConfirmation.files.contains(where: { ids.contains($0.id) }) {
            self.pendingConfirmation = pendingConfirmation.pruning(removedFileIDs: ids)
        }
        if !managerSelection.isDisjoint(with: ids) { managerSelection.subtract(ids) }
        if let previewed = preview.file, ids.contains(previewed.id) { preview.close() }
    }

    /// Requests an iCloud download for each file that isn't already local, resolving every URL
    /// under one transient scoped session — the browse-time entry point (the cloud badge tap and
    /// the Download menu command), where the playlist holds no open playback session. Each target
    /// is optimistically marked `.downloading` for immediate badge feedback, since the live status
    /// feed runs only for a *playing* channel; the feed or the next scan settles it to `.local` once
    /// the bytes land. Already-local files are skipped, so a fully-local selection opens no session.
    func downloadFiles(_ files: [PlaylistFile]) {
        let targets = files.filter { $0.cloudStatus != .local }
        guard let playlist = targets.first?.playlist else { return }
        withFolderAccess(to: playlist) { folderURL in
            for file in targets {
                cloudFileService.requestDownload(at: folderURL.appending(path: file.relativePath))
                file.cloudStatus = .downloading
            }
        }
    }

    /// Removes the audio track from each video, remuxing it in place (the video
    /// stream is copied, not re-encoded). The original is moved to the Trash as a
    /// recoverable backup and the audio-free file takes its place; a video currently
    /// on screen is reloaded and resumed at its position. Returns a message when some
    /// files couldn't be processed, with the first cause.
    func stripAudio(from files: [PlaylistFile]) async -> String? {
        // The whole batch is busy up front: a file queued behind the remux in progress must not
        // be moved or trashed before its own turn comes. Each file is released when its own strip
        // ends.
        await withFileOp(files) { files, _, folderURL, release in
            var failed = 0
            var firstCause: String?
            for file in files {
                let cause = await stripAudio(file, in: folderURL)
                release(file)
                // A swapped file's cached facts describe the pre-strip bytes; the swap forgot them
                // (below), so persist the clear before the next file's remux suspends — an unsaved
                // `nil` would be refaulted back to the stored value by any
                // `includePendingChanges = false` object fetch in between. The gallery's
                // `thumbnailKey` tracks `fingerprint`, so the cleared tile then regenerates. The
                // lists refresh once, after the loop.
                if let cause {
                    failed += 1
                    firstCause = firstCause ?? cause
                } else {
                    persistChanges()
                }
            }
            if failed < files.count { sequences.bump() }
            return batchFailure(failed, of: files.count, couldnt: "have their audio removed", cause: firstCause)
        }
    }

    /// Remuxes one file without its audio and swaps it in, with the playlist folder's
    /// scoped access already open. Returns the cause of a failure, `nil` on success.
    private func stripAudio(_ file: PlaylistFile, in folderURL: URL) async -> String? {
        let fm = FileManager.default
        let source = folderURL.appending(path: file.relativePath)
        guard fm.fileExists(atPath: source.path) else { return FileSystemError.fileNotFound.userMessage }

        // mpv writes the result beside the original as a hidden sibling: a scan in
        // flight skips dotfiles, and a same-volume rename into place can't fail for
        // space once the bytes are written. Cleaned up if anything before the swap fails.
        let sidecar = source.deletingLastPathComponent()
            .appending(path: ".shutapla-strip-\(UUID().uuidString).\(source.pathExtension)")
        defer { try? fm.removeItem(at: sidecar) }

        if let failure = await AudioStripper.stripAudio(at: source, to: sidecar) { return failure }

        // Capture the live position just before the swap so the reload looks seamless,
        // and whether playback was paused so the reload doesn't resume it. Only the file
        // showing on the visual channel needs reloading.
        let onScreen = coordinator.visualCurrentFile?.id == file.id ? coordinator.liveVisualPlaylist : nil
        let resumeAt = onScreen != nil ? coordinator.visualCurrentTime : nil
        let wasPaused = onScreen?.playbackState == .paused

        do {
            try fm.trashItem(at: source, resultingItemURL: nil)
            try fm.moveItem(at: sidecar, to: source)
        } catch {
            return error.localizedDescription
        }

        // The player still holds the trashed original open; reload the path to pick up
        // the audio-free file and seek back to where it was.
        if let onScreen, let resumeAt {
            coordinator.jump(onScreen, to: file)
            coordinator.seek(onScreen, to: resumeAt)
            if wasPaused { coordinator.pause(onScreen) }
        }
        // The audio-free file is different content; forget the cached facts so the next display
        // re-extracts. The caller persists the clear.
        file.invalidateMetadata()
        return nil
    }

    /// Reshuffles the playable files into a new random order; skipped files keep
    /// their place after the playable ones and are never shuffled in.
    func reshuffle(_ playlist: Playlist) {
        let playable = FileSystemService.fisherYatesShuffle(playlist.files.filter { !$0.isSkipped })
        let skipped = playlist.files.filter(\.isSkipped)
        for (index, file) in playable.enumerated() { file.sortOrder = index }
        for (offset, file) in skipped.enumerated() { file.sortOrder = playable.count + offset }
        playlist.clearResumePositions()   // a new shuffle axis voids every remembered position
        persistAndRefresh()
    }

    /// Reveals a file in the Finder.
    func revealInFinder(_ file: PlaylistFile) {
        guard let playlist = file.playlist else { return }
        withFolderAccess(to: playlist) { folderURL in
            NSWorkspace.shared.activateFileViewerSelecting([folderURL.appending(path: file.relativePath)])
        }
    }

    // MARK: - Tag editing

    /// Adds a tag to each of `files`, renaming on disk. Invalid-tagging files are
    /// skipped (they can't take a tag until their name parses cleanly), and files
    /// that already have the tag are unchanged. Returns a message when a file fails.
    @discardableResult
    func addTag(_ tag: String, to files: [PlaylistFile]) async -> String? {
        await applyTagRenames(tagRenames(files) { TagParser.addTag(tag, to: $0) }).error
    }

    /// Removes a tag from each of `files` that has it, renaming on disk.
    @discardableResult
    func removeTag(_ tag: String, from files: [PlaylistFile]) async -> String? {
        await applyTagRenames(tagRenames(files) { TagParser.removeTag(tag, from: $0) }).error
    }

    /// Replaces a tag with another in the name of every file in the playlist that carries it. A
    /// tag that files already carry merges: a file with both keeps one. A busy carrier refuses the
    /// whole replace, so a deliberate refusal never splits the tag.
    ///
    /// The filter follows the files: it is rewritten when a file changed, and kept when carriers
    /// remain and none changed (every file failed on disk, or the folder could not be opened). A
    /// partial failure splits the tag, and the filter follows the files that changed; a repeat
    /// replace finishes the rest. A tag that only a filter carries still changes there.
    ///
    /// An empty entry or the same tag (case aside) changes nothing; an invalid tag is refused with
    /// its message.
    @discardableResult
    func replaceTagAcrossPlaylist(_ playlist: Playlist, _ oldTag: String, with entry: String) async -> String? {
        let newTag = entry.trimmingCharacters(in: .whitespaces)
        guard newTag.isNotEmpty, !TagParser.sameTag(newTag, oldTag) else { return nil }
        guard TagParser.isValidTag(newTag) else {
            return "“\(newTag)” isn’t a valid tag (letters, digits, or underscore; at least \(TagParser.minTagLength) characters)."
        }
        return await editTagAcrossPlaylist(playlist) { TagParser.replaceTag(oldTag, with: newTag, in: $0) } followFilter: {
            playlist.rewriteFilterTag { TagParser.sameTag($0, oldTag) ? newTag : $0 }
        }
    }

    /// Removes a tag from every file in the playlist that carries it. A busy carrier refuses, and
    /// the filter follows the files, as in `replaceTagAcrossPlaylist`.
    @discardableResult
    func removeTagAcrossPlaylist(_ playlist: Playlist, tag: String) async -> String? {
        await editTagAcrossPlaylist(playlist) { TagParser.removeTag(tag, from: $0) } followFilter: {
            // Nothing is modal while the renames run, so the live strip can have raised a delete for
            // a search this drop cascades away; the confirmation's reference is then all that points
            // at the row. Let go of it, as a re-scan prunes a confirmation whose files it removed.
            // Compared by identity: nothing is read off the gone rows.
            let destroyed = playlist.dropFilterTag(tag)
            if case .savedSearchDelete(let search) = pendingConfirmation, destroyed.contains(where: { $0 === search }) {
                pendingConfirmation = nil
            }
        }
    }

    /// The playlist-wide tag edit: renames each carrier by `transform`, then changes the filter by
    /// `followFilter` unless carriers remain and none changed. A busy carrier refuses the edit.
    private func editTagAcrossPlaylist(
        _ playlist: Playlist, transform: (String) -> String, followFilter: () -> Void
    ) async -> String? {
        let renames = tagRenames(playlist.files, transform: transform)
        if let busy = busyNotice(renames.map(\.file)) { return busy }
        let carrierIDs = renames.map(\.file.id)
        let (changed, error) = await applyTagRenames(renames)
        // The re-scan the renames await can prune every carrier.
        guard changed > 0 || modelContext.files(withIDs: carrierIDs).isEmpty else { return error }
        followFilter()
        persistAndRefresh()   // the filter rewrite changes the effective filter
        return error
    }

    /// The renames a filename transform asks of `files`. Invalid-tagging files are excluded;
    /// transforms that leave a name unchanged are skipped so no needless disk renames happen.
    private func tagRenames(
        _ files: [PlaylistFile], transform: (String) -> String
    ) -> [(file: PlaylistFile, newName: String)] {
        files.compactMap { file in
            guard file.taggingStatus != .invalid else { return nil }
            let newName = transform(file.fileName)
            return newName == file.fileName ? nil : (file, newName)
        }
    }

    /// Applies `renames` in one scoped-access session, folding each file's tag change into the
    /// frequency cache as a delta. Returns the count of changed files, and the message for the
    /// failed ones (`batchFailure`).
    private func applyTagRenames(
        _ renames: [(file: PlaylistFile, newName: String)]
    ) async -> (changed: Int, error: String?) {
        var changed = 0
        // The whole batch is busy until the last rename: a move or trash of a file still queued
        // would leave the loop to read a deleted row. `persistentModelID` is the one safe read on
        // a row the op did not claim or the re-scan pruned (`existsInStore`).
        let error = await withFileOp(renames.map(\.file)) { files, playlist, folderURL, _ in
            let live = Set(files.map(\.persistentModelID))
            var errors: [String] = []
            for (file, newName) in renames where live.contains(file.persistentModelID) {
                let before = file.tagFrequencyNames
                if let error = await applyRename(file, to: newName, in: folderURL) {
                    errors.append(error)
                    continue
                }
                changed += 1
                modelContext.applyTagFrequencyDelta(to: playlist, before: before, after: file.tagFrequencyNames)
                // Save before the next rename suspends: an `includePendingChanges = false` object
                // fetch in between would refault the unsaved rename back to the old path. The lists
                // refresh once, after the loop.
                persistChanges()
            }
            if changed > 0 { sequences.bump() }
            return batchFailure(errors.count, of: errors.count + changed, couldnt: "be renamed", cause: errors.first)
        }
        return (changed, error)
    }
}

/// The notice for a batch file op, `nil` when no file failed. One file gives its cause alone: the
/// notice's title names the op. Several give the count ("N of M files couldn't <outcome>."), then
/// the first cause. `total` counts the files the op had to change.
private func batchFailure(_ failed: Int, of total: Int, couldnt outcome: String, cause: String?) -> String? {
    guard failed > 0 else { return nil }
    if total == 1, let cause { return cause }
    return ["\(failed) of \(total) files couldn't \(outcome).", cause].compactMap { $0 }.joined(separator: "\n")
}

private func batchFailure(_ result: FileBatchResult, couldnt outcome: String) -> String? {
    batchFailure(result.failed.count, of: result.failed.count + result.succeeded.count, couldnt: outcome, cause: result.firstError)
}
