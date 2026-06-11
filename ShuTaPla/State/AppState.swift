//
//  AppState.swift
//  ShuTaPla
//
//  The main-actor runtime state object: it owns the `ModelContext`, the current
//  app mode, and the active-playlist references, and drives the folder-picker →
//  scan → playlist-creation flow. Injected into the SwiftUI environment so every
//  view reads the same instance.
//

import Foundation
import SwiftData
import Observation
import AppKit

/// What the single window is currently showing.
enum AppMode {
    case welcome   // no playlists yet
    case manager   // library / file management
    case player    // fullscreen playback
}

/// A scanned folder awaiting a media-type decision because no type dominated it
/// (a Mixed folder). The view presents the choice and calls back with the type.
struct PendingPlaylist {
    let name: String
    let bookmark: Data
    let folderPath: String
    let scan: ScanResult
}

/// Outcome of picking a folder and scanning it.
enum AddPlaylistOutcome {
    /// A single dominant type was detected; the playlist was created.
    case created(Playlist)
    /// The folder is Mixed; the caller must prompt for a media type and then
    /// call `confirmPlaylist(_:mediaType:)`.
    case needsTypeChoice(PendingPlaylist)
    /// No recognized media files were found.
    case empty
    /// Bookmark creation or scanning failed.
    case failed(String)
}

@MainActor
@Observable
final class AppState {

    let modelContext: ModelContext
    private let fileSystem: FileSystemProviding
    let bookmarkService: BookmarkService

    private(set) var appStateModel: AppStateModel
    private(set) var globalSettings: GlobalSettings

    var mode: AppMode

    // Runtime references to the active playlists. The visual channel is shared:
    // at most one of video/image is non-nil. Audio is an independent channel.
    var activeVideoPlaylist: Playlist?
    var activeImagePlaylist: Playlist?
    var activeAudioPlaylist: Playlist?

    /// The playlist the Manager center panel is currently showing. Selecting a
    /// row in the sidebar sets this and activates the playlist for its channel.
    var selectedPlaylist: Playlist?

    /// In-flight background re-scan started by `select`. Tracked so a newer
    /// selection (or a delete) can cancel a stale update, and so tests can await
    /// it to completion.
    private(set) var updateTask: Task<Void, Never>?

    /// File-list selection in the Manager center panel, by file ID. Cleared when
    /// the selected playlist changes. The tag panel (Task 7) reads this.
    var selectedFileIDs: Set<UUID> = []

    init(
        modelContext: ModelContext,
        fileSystem: FileSystemProviding = FileSystemService(),
        bookmarkService: BookmarkService = BookmarkService()
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.bookmarkService = bookmarkService
        self.appStateModel = AppStateModel.fetchOrCreate(in: modelContext)
        self.globalSettings = GlobalSettings.fetchOrCreate(in: modelContext)

        // Welcome until at least one playlist exists. Player mode is only ever
        // entered at runtime (Task 16 handles resume), never restored here.
        let existing = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        self.mode = existing.isEmpty ? .welcome : .manager

        resolveActivePlaylists()
    }

    // MARK: - Active playlist references

    /// Restores runtime references from the persisted active-playlist IDs.
    private func resolveActivePlaylists() {
        activeVideoPlaylist = appStateModel.activeVideoPlaylistId.flatMap(playlist(withID:))
        activeImagePlaylist = appStateModel.activeImagePlaylistId.flatMap(playlist(withID:))
        activeAudioPlaylist = appStateModel.activeAudioPlaylistId.flatMap(playlist(withID:))
        selectedPlaylist = activeVideoPlaylist ?? activeImagePlaylist ?? activeAudioPlaylist
    }

    private func playlist(withID id: UUID) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Makes `playlist` the active one for its channel, persisting the choice.
    /// Activating a visual playlist clears the other visual channel.
    func activate(_ playlist: Playlist) {
        switch playlist.mediaType {
        case .video:
            activeVideoPlaylist = playlist
            activeImagePlaylist = nil
            appStateModel.activeVideoPlaylistId = playlist.id
            appStateModel.activeImagePlaylistId = nil
        case .image:
            activeImagePlaylist = playlist
            activeVideoPlaylist = nil
            appStateModel.activeImagePlaylistId = playlist.id
            appStateModel.activeVideoPlaylistId = nil
        case .audio:
            activeAudioPlaylist = playlist
            appStateModel.activeAudioPlaylistId = playlist.id
        }
    }

    // MARK: - Playlist creation

    /// Picks up a user-selected folder: creates a bookmark, scans, and either
    /// creates the playlist (single dominant type) or reports that a type choice
    /// is needed (Mixed) or that the folder is empty.
    func addPlaylist(from url: URL) async -> AddPlaylistOutcome {
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

        for (index, scanned) in ordered.enumerated() {
            let file = PlaylistFile(
                relativePath: scanned.relativePath,
                fileName: scanned.fileName,
                tags: scanned.tags,
                taggingStatus: scanned.taggingStatus,
                isSkipped: scanned.mediaType != mediaType,
                sortOrder: index
            )
            file.cloudStatus = scanned.cloudStatus
            file.playlist = playlist
            modelContext.insert(file)
        }
        rebuildTagFrequency(playlist)

        activate(playlist)
        selectedPlaylist = playlist
        if mode == .welcome { mode = .manager }
        return playlist
    }

    /// Next sort order within a media type's sidebar section (appended last).
    private func nextSortOrder(for mediaType: MediaType) -> Int {
        let all = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        return all.filter { $0.mediaType == mediaType }.count
    }

    // MARK: - Manager operations

    /// Makes `playlist` the Manager selection, activates it for its channel, and
    /// kicks off a background re-scan to pick up files added or removed on disk.
    func select(_ playlist: Playlist) {
        if selectedPlaylist !== playlist { selectedFileIDs = [] }
        selectedPlaylist = playlist
        activate(playlist)
        updateTask?.cancel()
        updateTask = Task { await update(playlist) }
    }

    /// Renames a playlist; an empty or whitespace-only name is rejected.
    func rename(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
    }

    /// Deletes a playlist (cascading to its files), clearing any active/selected
    /// reference to it, and compacts the remaining sort orders in its section.
    func delete(_ playlist: Playlist) {
        updateTask?.cancel()
        if selectedPlaylist === playlist { selectedPlaylist = nil }
        if activeVideoPlaylist === playlist {
            activeVideoPlaylist = nil
            appStateModel.activeVideoPlaylistId = nil
        }
        if activeImagePlaylist === playlist {
            activeImagePlaylist = nil
            appStateModel.activeImagePlaylistId = nil
        }
        if activeAudioPlaylist === playlist {
            activeAudioPlaylist = nil
            appStateModel.activeAudioPlaylistId = nil
        }
        let mediaType = playlist.mediaType
        modelContext.delete(playlist)
        compactSortOrder(for: mediaType)
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

    /// Re-scans a playlist's folder and applies the delta: prunes files missing
    /// from disk, appends new ones. Failures (e.g. a stale bookmark) are ignored
    /// here; the file list simply stays as it was.
    func update(_ playlist: Playlist) async {
        guard !Task.isCancelled else { return }
        let known = Set(playlist.files.map(\.relativePath))
        let delta: UpdateDelta
        do {
            delta = try await fileSystem.updatePlaylist(
                bookmark: playlist.folderBookmark,
                knownRelativePaths: known
            )
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        apply(delta, to: playlist)
    }

    private func apply(_ delta: UpdateDelta, to playlist: Playlist) {
        guard !delta.added.isEmpty || !delta.removedRelativePaths.isEmpty else { return }

        let removed = Set(delta.removedRelativePaths)
        let toRemove = playlist.files.filter { removed.contains($0.relativePath) }
        for file in toRemove {
            file.playlist = nil  // detach so playlist.files updates synchronously
            modelContext.delete(file)
        }

        var nextOrder = (playlist.files.map(\.sortOrder).max() ?? -1) + 1
        for scanned in delta.added {
            let file = PlaylistFile(
                relativePath: scanned.relativePath,
                fileName: scanned.fileName,
                tags: scanned.tags,
                taggingStatus: scanned.taggingStatus,
                isSkipped: scanned.mediaType != playlist.mediaType,
                sortOrder: nextOrder
            )
            file.cloudStatus = scanned.cloudStatus
            file.playlist = playlist
            modelContext.insert(file)
            nextOrder += 1
        }

        rebuildTagFrequency(playlist)
    }

    /// Recomputes the per-playlist tag usage counts from its playable files.
    private func rebuildTagFrequency(_ playlist: Playlist) {
        var frequency: [String: Int] = [:]
        for file in playlist.files where !file.isSkipped {
            for tag in file.tags { frequency[tag, default: 0] += 1 }
        }
        playlist.tagFrequency = frequency
    }

    /// Renumbers a section's `sortOrder` values to 0..<count after a deletion.
    private func compactSortOrder(for mediaType: MediaType) {
        let all = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        let section = all
            .filter { $0.mediaType == mediaType }
            .sorted { $0.sortOrder < $1.sortOrder }
        for (index, playlist) in section.enumerated() {
            playlist.sortOrder = index
        }
    }

    // MARK: - File operations

    /// Renames a file on disk, then updates the model (name, relative path, and
    /// re-parsed tags). Returns a user-facing message on failure, `nil` on success.
    func renameFile(_ file: PlaylistFile, to newName: String) async -> String? {
        guard let playlist = file.playlist else { return "This file isn't in a playlist." }
        let folderURL: URL
        do {
            folderURL = try bookmarkService.startAccess(to: playlist.folderBookmark)
        } catch {
            return "Couldn't access the playlist folder."
        }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }

        let newURL: URL
        do {
            newURL = try await fileSystem.renameFile(
                at: folderURL.appending(path: file.relativePath),
                to: newName
            )
        } catch let error as FileSystemError {
            return message(for: error)
        } catch {
            return "Rename failed."
        }

        let finalName = newURL.lastPathComponent
        let parent = (file.relativePath as NSString).deletingLastPathComponent
        file.fileName = finalName
        file.relativePath = parent.isEmpty ? finalName : "\(parent)/\(finalName)"
        let (tags, status) = tagFields(for: finalName)
        file.tags = tags
        file.taggingStatus = status
        rebuildTagFrequency(playlist)
        return nil
    }

    /// Moves files to the Trash (best effort) and removes the trashed ones from
    /// the playlist. Returns a message when some files couldn't be trashed.
    func deleteFiles(_ files: [PlaylistFile]) async -> String? {
        guard let playlist = files.first?.playlist else { return nil }
        let folderURL: URL
        do {
            folderURL = try bookmarkService.startAccess(to: playlist.folderBookmark)
        } catch {
            return "Couldn't access the playlist folder."
        }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }

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
            selectedFileIDs.remove(file.id)
            file.playlist = nil
            modelContext.delete(file)
        }
        rebuildTagFrequency(playlist)

        guard result.failed.isEmpty else {
            return "\(result.failed.count) file(s) couldn't be moved to the Trash."
        }
        return nil
    }

    /// Reshuffles the playable files into a new random order; skipped files keep
    /// their place after the playable ones and are never shuffled in.
    func reshuffle(_ playlist: Playlist) {
        let playable = FileSystemService.fisherYatesShuffle(playlist.files.filter { !$0.isSkipped })
        let skipped = playlist.files.filter(\.isSkipped)
        for (index, file) in playable.enumerated() { file.sortOrder = index }
        for (offset, file) in skipped.enumerated() { file.sortOrder = playable.count + offset }
    }

    /// Reveals a file in the Finder.
    func revealInFinder(_ file: PlaylistFile) {
        guard let playlist = file.playlist,
              let folderURL = try? bookmarkService.startAccess(to: playlist.folderBookmark) else { return }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL.appending(path: file.relativePath)])
    }

    /// Temporary playback entry point until the PlaybackCoordinator (Task 11).
    /// Records the starting file and switches the window to Player mode.
    func beginPlayback(of playlist: Playlist, startingAt file: PlaylistFile? = nil) {
        if let file { playlist.currentFileID = file.id }
        activate(playlist)
        selectedPlaylist = playlist
        mode = .player
    }

    private func tagFields(for fileName: String) -> ([String], TaggingStatus) {
        switch TagParser.parseTags(from: fileName) {
        case .valid(let tags): return (tags, .valid)
        case .untagged: return ([], .untagged)
        case .invalid: return ([], .invalid)
        }
    }

    private func message(for error: FileSystemError) -> String {
        switch error {
        case .invalidName: return "That name isn't valid."
        case .nameCollision: return "A file with that name already exists."
        case .fileNotFound: return "The file no longer exists on disk."
        case .operationFailed(let detail): return "Rename failed: \(detail)"
        }
    }
}
