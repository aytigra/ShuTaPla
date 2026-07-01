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

        let name = url.lastPathComponent
        let folderPath = url.path(percentEncoded: false)

        if scan.isEmpty { return .empty }

        if let type = scan.dominantType {
            let playlist = makePlaylist(name: name, bookmark: bookmark, folderPath: folderPath, scan: scan, mediaType: type)
            return .created(playlist)
        }

        return .needsTypeChoice(
            PendingPlaylist(name: name, bookmark: bookmark, folderPath: folderPath, scan: scan)
        )
    }

    /// Completes creation of a Mixed-folder playlist once the user chooses a type.
    @discardableResult
    func confirmPlaylist(_ pending: PendingPlaylist, mediaType: MediaType) -> Playlist {
        makePlaylist(
            name: pending.name,
            bookmark: pending.bookmark,
            folderPath: pending.folderPath,
            scan: pending.scan,
            mediaType: mediaType
        )
    }

    /// Folder-picker callback for the shared add flow: scans the folder and either creates
    /// the playlist, raises the media-type choice (Mixed), or sets an error (empty/failed),
    /// driving the observable state the `AddPlaylistFlow` modifier presents.
    func importPlaylist(from url: URL) async {
        isAddingPlaylist = true
        defer { isAddingPlaylist = false }
        switch await addPlaylist(from: url) {
        case .created:
            break   // makePlaylist switches to manager mode and selects it
        case .needsTypeChoice(let pending):
            pendingTypeChoice = pending
        case .empty:
            addPlaylistError = "“\(url.lastPathComponent)” has no videos, images, or audio files."
        case .failed(let message):
            addPlaylistError = message
        }
    }

    /// Resolves the pending media-type choice: creates the Mixed-folder playlist with the
    /// chosen type and dismisses the dialog.
    func confirmPendingTypeChoice(_ mediaType: MediaType) {
        guard let pending = pendingTypeChoice else { return }
        confirmPlaylist(pending, mediaType: mediaType)
        pendingTypeChoice = nil
    }

    /// Builds and persists a `Playlist` and its `PlaylistFile`s from a scan.
    /// Files whose media type differs from the playlist's are marked skipped
    /// (kept for the skipped-files filter, never played). Playable files are
    /// shuffled to seed the initial order.
    @discardableResult
    func makePlaylist(
        name: String,
        bookmark: Data,
        folderPath: String,
        scan: ScanResult,
        mediaType: MediaType
    ) -> Playlist {
        let playlist = Playlist(
            name: name,
            folderBookmark: bookmark,
            folderPath: folderPath,
            mediaType: mediaType,
            sortOrder: nextSortOrder(for: mediaType)
        )
        modelContext.insert(playlist)

        // Shuffle so the initial playback order is randomized; skipped files are
        // ordered after the playable ones and never enter playback.
        let ordered = FileSystemService.fisherYatesShuffle(scan.files)
            .sorted { ($0.mediaType == mediaType ? 0 : 1) < ($1.mediaType == mediaType ? 0 : 1) }

        // Insert naked rows only — no filename-tag derivation on the main actor; that runs in the
        // background below, the same actor path Update uses. Skip status is set here (a row whose
        // type differs from the playlist's is skipped), so playback ordering is correct at once.
        for (index, scanned) in ordered.enumerated() {
            modelContext.makeFile(from: scanned, in: playlist, sortOrder: index)
        }
        // Persist the inserted rows before anything derives a sequence from them: a player-mode
        // creation starts playback (which reads the playback sequence) right below, and the
        // background derivation resolves the playlist by id from the committed store.
        persistAndRefresh()

        // Player-mode creation comes from a playback overlay (the Visual Overlay or the
        // audio overlay) and starts the new playlist playing; Manager-mode creation loads it
        // stopped. A player-mode creation only *remembers* the playlist (so stopping back into
        // Manager returns to whatever was being managed), while a management creation loads it
        // into the managed slot and switches the scope to its type.
        let startsPlaying = mode == .player
        if startsPlaying {
            remember(playlist)
            coordinator.play(playlist)
        } else {
            // Only one audio playlist is ever live; releasing the channel keeps a background
            // playlist from playing on behind a stopped audio creation.
            if mediaType == .audio, let live = coordinator.liveAudioPlaylist { coordinator.stop(live) }
            setManaged(playlist)
            managerSelection = []
        }
        if mode == .welcome { mode = .manager }

        // Derive filename tags / `tagFrequency` off the main actor, reusing the scan in hand (no
        // disk re-read), through the same actor + apply path Update uses. On this freshly-created
        // playlist every row is present (matched by relative path), so the reconcile only derives
        // tags. Tracked so a delete can cancel it and tests can await it.
        trackBackgroundTask(for: playlist.id) { await self.deriveInBackground(playlist, from: scan.files) }
        return playlist
    }

    /// Next sort order within a media type's sidebar section (appended last).
    private func nextSortOrder(for mediaType: MediaType) -> Int {
        modelContext.playlists(ofType: mediaType).count
    }
}
