//
//  AppState+Creation.swift
//  ShuTaPla
//
//  The add-folder → scan → playlist-creation flow: bookmarking and scanning a picked folder,
//  resolving a Mixed folder's media-type choice, and building the `Playlist` and its naked
//  `PlaylistFile` rows (tags derived in the background).
//

import Foundation
import SwiftData

extension AppState {

    /// Picks up a user-selected folder: creates a bookmark, scans, and either
    /// creates the playlist (single dominant type) or reports that a type choice
    /// is needed (Mixed) or that the folder is empty.
    func addPlaylist(from url: URL) async -> AddPlaylistOutcome {
        let importing = ImportingPlaylist(name: url.lastPathComponent)
        importingPlaylists.append(importing)
        defer { importingPlaylists.removeAll { $0.id == importing.id } }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let bookmark: Data
        do {
            bookmark = try BookmarkService.makeBookmark(for: url)
        } catch {
            return .failed("Couldn't access \(url.lastPathComponent).")
        }

        let scan: ScanResult
        do {
            scan = try await fileSystem.scanFolder(bookmark: bookmark)
        } catch {
            return .failed("Couldn't scan \(url.lastPathComponent).")
        }

        if scan.isEmpty { return .empty }

        let folder = ScannedFolder(
            name: url.lastPathComponent, bookmark: bookmark, folderPath: url.path(percentEncoded: false), scan: scan
        )
        guard let type = scan.dominantType else { return .needsTypeChoice(folder) }
        return .created(makePlaylist(from: folder, mediaType: type))
    }

    /// Folder-picker callback for the shared add flow: scans the folder and either creates
    /// the playlist, raises the media-type choice (Mixed), or reports a failure (empty/failed).
    func importPlaylist(from url: URL) async {
        isAddingPlaylist = true
        defer { isAddingPlaylist = false }
        switch await addPlaylist(from: url) {
        case .created:
            break   // makePlaylist places the new playlist
        case .needsTypeChoice(let folder):
            pendingTypeChoice = folder
        case .empty:
            report(.addPlaylistFailed("“\(url.lastPathComponent)” has no videos, images, or audio files."))
        case .failed(let message):
            report(.addPlaylistFailed(message))
        }
    }

    /// Resolves the pending media-type choice: creates the Mixed-folder playlist with the
    /// chosen type and dismisses the dialog.
    func confirmPendingTypeChoice(_ mediaType: MediaType) {
        guard let folder = pendingTypeChoice else { return }
        makePlaylist(from: folder, mediaType: mediaType)
        pendingTypeChoice = nil
    }

    /// Builds and persists a `Playlist` and its `PlaylistFile`s from a scanned folder.
    /// Files whose media type differs from the playlist's are marked skipped
    /// (kept for the skipped-files filter, never played). Playable files are
    /// shuffled to seed the initial order.
    @discardableResult
    func makePlaylist(from folder: ScannedFolder, mediaType: MediaType) -> Playlist {
        let playlist = Playlist(
            name: folder.name,
            folderBookmark: folder.bookmark,
            folderPath: folder.folderPath,
            mediaType: mediaType,
            sortOrder: nextSortOrder(for: mediaType)
        )
        modelContext.insert(playlist)

        // Shuffle so the initial playback order is randomized; skipped files are
        // ordered after the playable ones and never enter playback.
        let ordered = FileSystemService.fisherYatesShuffle(folder.scan.files)
            .sorted { ($0.mediaType == mediaType ? 0 : 1) < ($1.mediaType == mediaType ? 0 : 1) }

        // Insert naked rows only — no filename-tag derivation on the main actor; that runs in the
        // background below, the same actor path Update uses. Skip status is set here (a row whose
        // type differs from the playlist's is skipped), so playback ordering is correct at once.
        for (index, scanned) in ordered.enumerated() {
            modelContext.makeFile(from: scanned, in: playlist, sortOrder: index)
        }
        // The background derivation resolves the playlist by id from the committed store.
        persistAndRefresh()
        notePlaylistsChanged()   // a new sidebar row

        // The mode at completion decides, not the entry point: a scan or a Mixed-folder type choice
        // can outlast a switch between Manager and Player mode. In Player mode the playlist only
        // joins its selector list.
        if mode != .player {
            // Only one audio playlist is ever live, and the new one becomes the Audio Channel Playlist.
            if mediaType == .audio, let live = coordinator.liveAudioPlaylist { coordinator.stop(live) }
            setManaged(playlist)
            managerSelection = []
            if mode == .welcome { mode = .manager }
        }

        // Derive filename tags / `tagFrequency` off the main actor, reusing the scan in hand (no
        // disk re-read), through the same actor + apply path Update uses. On this freshly-created
        // playlist every row is present (matched by relative path), so the reconcile only derives
        // tags. Tracked so a delete can cancel it and tests can await it.
        trackBackgroundTask(for: playlist.id) { await self.deriveInBackground(playlist, from: folder.scan.files) }
        return playlist
    }

    /// Next sort order within a media type's sidebar section (appended last).
    private func nextSortOrder(for mediaType: MediaType) -> Int {
        modelContext.playlists(ofType: mediaType).count
    }
}
