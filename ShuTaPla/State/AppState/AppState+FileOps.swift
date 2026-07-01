//
//  AppState+FileOps.swift
//  ShuTaPla
//
//  The file-level edits that touch the disk through one-shot scoped folder access: rename,
//  trash, remove-audio, reshuffle, reveal-in-Finder, and the tag edits (which rename files on
//  disk too). `applyRename`/`editTags` are the shared disk-rename core the tag edits reuse.
//

import Foundation
import SwiftData
import AppKit

extension AppState {

    // MARK: - File operations

    /// Renames a file on disk, then updates the model (name, relative path, and
    /// re-parsed tags). Returns a user-facing message on failure, `nil` on success.
    func renameFile(_ file: PlaylistFile, to newName: String) async -> String? {
        guard let playlist = file.playlist else { return "This file isn't in a playlist." }
        return await folderAccess.withAccess(to: playlist) { folderURL in
            if let error = await applyRename(file, to: newName, in: folderURL) { return error }
            modelContext.rebuildTagFrequency(of: playlist)
            persistAndRefresh()
            return nil
        } ?? nil
    }

    /// Renames one file on disk and mirrors the result onto the model, with the
    /// playlist folder's scoped access already open. Returns a message on failure.
    /// Callers rebuild the tag-frequency cache once after a batch.
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
    /// the playlist. Returns a message when some files couldn't be trashed.
    func deleteFiles(_ files: [PlaylistFile]) async -> String? {
        guard let playlist = files.first?.playlist else { return nil }
        return await folderAccess.withAccess(to: playlist) { folderURL in
            var byURL: [URL: PlaylistFile] = [:]
            for file in files { byURL[folderURL.appending(path: file.relativePath)] = file }

            let result: TrashResult
            do {
                result = try await fileSystem.trashFiles(Array(byURL.keys))
            } catch {
                return "Delete failed."
            }

            for url in result.trashed {
                guard let file = byURL[url] else { continue }
                managerSelection.remove(file.id)
                file.playlist = nil
                modelContext.delete(file)
            }
            modelContext.rebuildTagFrequency(of: playlist)
            persistAndRefresh()
            // Advance whichever channel was playing this playlist off a trashed track, so the
            // engine never holds a file that's no longer in the playlist. Covers every delete
            // entry point (Manager list, Visual Overlay, audio overlay) in one place.
            coordinator.reconcile(playlistThatChanged: playlist)

            guard result.failed.isEmpty else {
                return "\(result.failed.count) file(s) couldn't be moved to the Trash."
            }
            return nil
        } ?? nil
    }

    /// Removes the audio track from each video, remuxing it in place (the video
    /// stream is copied, not re-encoded). The original is moved to the Trash as a
    /// recoverable backup and the audio-free file takes its place; a video currently
    /// on screen is reloaded and resumed at its position. Returns a message when some
    /// files couldn't be processed.
    func stripAudio(from files: [PlaylistFile]) async -> String? {
        guard let playlist = files.first?.playlist else { return nil }
        return await folderAccess.withAccess(to: playlist) { folderURL in
            var failed = 0
            for file in files {
                strippingFileIDs.insert(file.id)
                let ok = await stripAudio(file, in: folderURL)
                strippingFileIDs.remove(file.id)
                if !ok { failed += 1 }
            }

            guard failed == 0 else {
                return failed == files.count
                    ? "Couldn't remove the audio."
                    : "\(failed) of \(files.count) files couldn't have their audio removed."
            }
            return nil
        } ?? nil
    }

    /// Remuxes one file without its audio and swaps it in, with the playlist folder's
    /// scoped access already open. Returns whether it succeeded.
    private func stripAudio(_ file: PlaylistFile, in folderURL: URL) async -> Bool {
        let fm = FileManager.default
        let source = folderURL.appending(path: file.relativePath)
        guard fm.fileExists(atPath: source.path) else { return false }

        // mpv writes the result beside the original as a hidden sibling: a scan in
        // flight skips dotfiles, and a same-volume rename into place can't fail for
        // space once the bytes are written. Cleaned up if anything before the swap fails.
        let sidecar = source.deletingLastPathComponent()
            .appending(path: ".shutapla-strip-\(UUID().uuidString).\(source.pathExtension)")
        defer { try? fm.removeItem(at: sidecar) }

        guard await AudioStripper.stripAudio(at: source, to: sidecar) else { return false }

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
            return false
        }

        // The player still holds the trashed original open; reload the path to pick up
        // the audio-free file and seek back to where it was.
        if let onScreen, let resumeAt {
            coordinator.jump(onScreen, to: file)
            coordinator.seek(onScreen, to: resumeAt)
            if wasPaused { coordinator.pause(onScreen) }
        }
        return true
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
        folderAccess.withAccess(to: playlist) { folderURL in
            NSWorkspace.shared.activateFileViewerSelecting([folderURL.appending(path: file.relativePath)])
        }
    }

    // MARK: - Tag editing

    /// Adds a tag to each of `files`, renaming on disk. Invalid-tagging files are
    /// skipped (they can't take a tag until their name parses cleanly), and files
    /// that already have the tag are unchanged. Returns the first failure message.
    @discardableResult
    func addTag(_ tag: String, to files: [PlaylistFile]) async -> String? {
        await editTags(files) { TagParser.addTag(tag, to: $0) }
    }

    /// Removes a tag from each of `files` that has it, renaming on disk.
    @discardableResult
    func removeTag(_ tag: String, from files: [PlaylistFile]) async -> String? {
        await editTags(files) { TagParser.removeTag(tag, from: $0) }
    }

    /// Renames a tag across every file in the playlist that carries it. Renaming onto
    /// another existing tag (a different tag that differs only in spelling/casing) is
    /// refused with a message rather than silently merging the two.
    @discardableResult
    func renameTagAcrossPlaylist(_ playlist: Playlist, from oldTag: String, to newTag: String) async -> String? {
        // Check every file's tags, not just `tagFrequency` (which counts only non-skipped
        // files) — a target tag carried solely by a skipped/invalid file is still a tag the
        // rename would silently merge onto.
        let collides = playlist.files.contains { file in
            file.tags.contains { TagParser.sameTag($0.name, newTag) && !TagParser.sameTag($0.name, oldTag) }
        }
        if collides { return "A tag named “\(newTag)” already exists." }
        let error = await editTags(playlist.files) { TagParser.renameTag(from: oldTag, to: newTag, in: $0) }
        playlist.rewriteFilterTag { TagParser.sameTag($0, oldTag) ? newTag : $0 }
        persistAndRefresh()   // the filter rewrite changes the effective filter
        return error
    }

    /// Removes a tag from every file in the playlist that carries it.
    @discardableResult
    func removeTagAcrossPlaylist(_ playlist: Playlist, tag: String) async -> String? {
        let error = await editTags(playlist.files) { TagParser.removeTag(tag, from: $0) }
        playlist.dropFilterTag(tag)
        persistAndRefresh()   // the filter rewrite changes the effective filter
        return error
    }

    /// Applies a filename transform to a batch of files (one scoped-access session,
    /// one tag-frequency rebuild). Invalid-tagging files are excluded; transforms
    /// that leave a name unchanged are skipped so no needless disk renames happen.
    private func editTags(_ files: [PlaylistFile], transform: (String) -> String) async -> String? {
        let editable = files.filter { $0.taggingStatus != .invalid }
        guard let playlist = editable.first?.playlist else { return nil }
        return await folderAccess.withAccess(to: playlist) { folderURL in
            var firstError: String?
            for file in editable {
                let newName = transform(file.fileName)
                guard newName != file.fileName else { continue }
                if let error = await applyRename(file, to: newName, in: folderURL) {
                    firstError = firstError ?? error
                }
            }
            modelContext.rebuildTagFrequency(of: playlist)
            persistAndRefresh()
            return firstError
        } ?? nil
    }
}
