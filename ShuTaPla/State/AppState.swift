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

/// A folder being scanned into a new playlist, shown optimistically in the
/// sidebar (with a spinner) until the finished playlist replaces it.
struct ImportingPlaylist: Identifiable {
    let id = UUID()
    let name: String
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

    /// Drives actual playback: owns the engines, enforces channel exclusivity, and
    /// resolves file URLs through `bookmarkService`. Injected into the player views.
    let coordinator: PlaybackCoordinator

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
    /// the selected playlist changes. The tag panel reads this.
    var selectedFileIDs: Set<UUID> = []

    /// Active runtime-only service filter (Untagged / Invalid tagging / Skipped).
    /// While set it overrides the selected playlist's persisted tag filter; it is
    /// mutually exclusive and never persisted.
    private(set) var activeServiceFilter: ServiceFilter?

    /// The selected playlist's files after the active filter, sorted for display.
    /// Cached so the file list doesn't refilter on every redraw; recomputed when
    /// the selection, filter, service filter, or file set changes.
    private(set) var filteredFiles: [PlaylistFile] = []

    /// Folders currently being scanned into new playlists, shown in the sidebar as
    /// transient spinner rows so a large import gives immediate feedback.
    private(set) var importingPlaylists: [ImportingPlaylist] = []

    /// IDs of existing playlists with a long-running operation in flight (e.g. a
    /// background re-scan), so their sidebar rows can show a spinner.
    private(set) var busyPlaylistIDs: Set<UUID> = []

    /// IDs of playlists currently being deleted (their files are being cleaned out
    /// in batches), so their sidebar rows can show a destructive red spinner.
    private(set) var deletingPlaylistIDs: Set<UUID> = []

    init(
        modelContext: ModelContext,
        fileSystem: FileSystemProviding = FileSystemService(),
        bookmarkService: BookmarkService = BookmarkService()
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.bookmarkService = bookmarkService
        self.appStateModel = AppStateModel.fetchOrCreate(in: modelContext)
        let settings = GlobalSettings.fetchOrCreate(in: modelContext)
        self.globalSettings = settings
        self.coordinator = PlaybackCoordinator(
            bookmarkService: bookmarkService,
            defaultSlideshowInterval: { settings.defaultSlideshowInterval }
        )

        // Welcome until at least one playlist exists. Player mode is only ever
        // entered at runtime (Task 16 handles resume), never restored here.
        let existing = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        self.mode = existing.isEmpty ? .welcome : .manager

        resolveActivePlaylists()
        recomputeFilteredFiles()
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
        activeServiceFilter = nil
        recomputeFilteredFiles()
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
        activeServiceFilter = nil   // service filters don't carry across playlists
        activate(playlist)
        recomputeFilteredFiles()    // show the restored per-playlist filter at once
        updateTask?.cancel()
        updateTask = Task { await update(playlist) }
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
        recomputeFilteredFiles()
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
        busyPlaylistIDs.insert(playlist.id)
        defer { busyPlaylistIDs.remove(playlist.id) }

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
        recomputeIfSelected(playlist)
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
        guard let folderURL = beginFolderAccess(to: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }

        if let error = await applyRename(file, to: newName, in: folderURL) { return error }
        rebuildTagFrequency(playlist)
        recomputeIfSelected(playlist)
        return nil
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
        return nil
    }

    /// Moves files to the Trash (best effort) and removes the trashed ones from
    /// the playlist. Returns a message when some files couldn't be trashed.
    func deleteFiles(_ files: [PlaylistFile]) async -> String? {
        guard let playlist = files.first?.playlist else { return nil }
        guard let folderURL = beginFolderAccess(to: playlist) else { return nil }
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
        recomputeIfSelected(playlist)

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
        recomputeIfSelected(playlist)
    }

    /// Reveals a file in the Finder.
    func revealInFinder(_ file: PlaylistFile) {
        guard let playlist = file.playlist,
              let folderURL = beginFolderAccess(to: playlist) else { return }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL.appending(path: file.relativePath)])
    }

    // MARK: - Folder access

    /// Returns the playlist's folder URL with a scoped-access session started, or
    /// `nil` if the user cancels. When the saved bookmark is stale or access is
    /// denied, the user is asked to locate the folder again and the bookmark is
    /// refreshed before access is retried. Each successful call must be balanced
    /// by `bookmarkService.stopAccess(to: playlist.folderBookmark)`.
    private func beginFolderAccess(to playlist: Playlist) -> URL? {
        if let url = try? bookmarkService.startAccess(to: playlist.folderBookmark) {
            return url
        }
        guard let url = promptForFolderAccess(to: playlist),
              refreshBookmark(of: playlist, from: url) else { return nil }
        return try? bookmarkService.startAccess(to: playlist.folderBookmark)
    }

    /// Re-creates and persists the playlist's bookmark from a freshly granted URL.
    private func refreshBookmark(of playlist: Playlist, from url: URL) -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? BookmarkService.makeBookmark(for: url) else { return false }
        playlist.folderBookmark = bookmark
        playlist.folderPath = url.path(percentEncoded: false)
        return true
    }

    /// Asks the user to point at the playlist's folder to re-grant access.
    private func promptForFolderAccess(to playlist: Playlist) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Locate “\(playlist.name)” to let ShuTaPla modify its files."
        panel.directoryURL = URL(fileURLWithPath: playlist.folderPath)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Starts a playlist playing through the coordinator. Visual playlists take the
    /// window into Player mode; an audio playlist plays in place (its overlay UI
    /// arrives in Task 15) and does not change mode.
    func beginPlayback(of playlist: Playlist, startingAt file: PlaylistFile? = nil) {
        activate(playlist)
        selectedPlaylist = playlist
        coordinator.play(playlist, startingAt: file)
        if playlist.mediaType != .audio { mode = .player }
    }

    /// Stops the visual playlist and returns the window to Manager mode (the pause
    /// overlay's Stop, and the temporary Back control).
    func stopAndExitPlayer() {
        if let visual = coordinator.visualPlaylist { coordinator.stop(visual) }
        coordinator.unsuppress()
        mode = .manager
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

    /// Renames a tag across every file in the playlist that carries it.
    @discardableResult
    func renameTagAcrossPlaylist(_ playlist: Playlist, from oldTag: String, to newTag: String) async -> String? {
        await editTags(playlist.files) { TagParser.renameTag(from: oldTag, to: newTag, in: $0) }
    }

    /// Removes a tag from every file in the playlist that carries it.
    @discardableResult
    func removeTagAcrossPlaylist(_ playlist: Playlist, tag: String) async -> String? {
        await editTags(playlist.files) { TagParser.removeTag(tag, from: $0) }
    }

    /// Applies a filename transform to a batch of files (one scoped-access session,
    /// one tag-frequency rebuild). Invalid-tagging files are excluded; transforms
    /// that leave a name unchanged are skipped so no needless disk renames happen.
    private func editTags(_ files: [PlaylistFile], transform: (String) -> String) async -> String? {
        let editable = files.filter { $0.taggingStatus != .invalid }
        guard let playlist = editable.first?.playlist else { return nil }
        guard let folderURL = beginFolderAccess(to: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }

        var firstError: String?
        for file in editable {
            let newName = transform(file.fileName)
            guard newName != file.fileName else { continue }
            if let error = await applyRename(file, to: newName, in: folderURL) {
                firstError = firstError ?? error
            }
        }
        rebuildTagFrequency(playlist)
        recomputeIfSelected(playlist)
        return firstError
    }

    // MARK: - Filtering

    /// Toggles a service filter on/off. Service filters are mutually exclusive and,
    /// while active, override the playlist's tag filter.
    func toggleServiceFilter(_ filter: ServiceFilter) {
        activeServiceFilter = (activeServiceFilter == filter) ? nil : filter
        recomputeFilteredFiles()
    }

    /// Adds or removes a tag from the selected playlist's tag filter. Editing the
    /// tag filter clears any active service filter.
    func toggleFilterTag(_ tag: String) {
        guard let playlist = selectedPlaylist else { return }
        activeServiceFilter = nil
        var tags = playlist.filterState.selectedTags
        if let index = tags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        playlist.filterState.selectedTags = tags
        recomputeFilteredFiles()
    }

    /// Sets the AND/OR operator on the selected playlist's tag filter.
    func setFilterMode(_ mode: FilterMode) {
        guard let playlist = selectedPlaylist else { return }
        playlist.filterState.filterMode = mode
        recomputeFilteredFiles()
    }

    /// Clears the selected playlist's tag filter.
    func clearTagFilter() {
        guard let playlist = selectedPlaylist else { return }
        playlist.filterState.selectedTags = []
        recomputeFilteredFiles()
    }

    /// Remembers the current tag filter as a saved search (most-recent first,
    /// unique by tag set + operator, capped at 10). No-op when the filter is empty.
    func saveCurrentSearch() {
        guard let playlist = selectedPlaylist, !playlist.filterState.isEmpty else { return }
        let search = SavedSearch(tags: playlist.filterState.selectedTags, mode: playlist.filterState.filterMode)
        promote(search, in: playlist)
    }

    /// Re-applies a saved search and moves it to the top of the recents.
    func applySavedSearch(_ search: SavedSearch) {
        guard let playlist = selectedPlaylist else { return }
        activeServiceFilter = nil
        playlist.filterState.selectedTags = search.tags
        playlist.filterState.filterMode = search.mode
        promote(search, in: playlist)
        recomputeFilteredFiles()
    }

    /// Removes a saved search from the recents.
    func removeSavedSearch(_ search: SavedSearch) {
        guard let playlist = selectedPlaylist else { return }
        playlist.savedSearches.removeAll { $0.matches(search) }
    }

    private func promote(_ search: SavedSearch, in playlist: Playlist) {
        var searches = playlist.savedSearches.filter { !$0.matches(search) }
        searches.insert(search, at: 0)
        playlist.savedSearches = Array(searches.prefix(10))
    }

    /// Recomputes `filteredFiles` for the current selection and active filter.
    func recomputeFilteredFiles() {
        guard let playlist = selectedPlaylist else { filteredFiles = []; return }
        filteredFiles = computeFilteredFiles(for: playlist)
    }

    private func recomputeIfSelected(_ playlist: Playlist) {
        if playlist === selectedPlaylist { recomputeFilteredFiles() }
    }

    private func computeFilteredFiles(for playlist: Playlist) -> [PlaylistFile] {
        let byOrder: (PlaylistFile, PlaylistFile) -> Bool = { $0.sortOrder < $1.sortOrder }

        // A service filter, while active, replaces the tag filter entirely.
        if let service = activeServiceFilter {
            switch service {
            case .untagged:
                return playlist.files.filter { !$0.isSkipped && $0.taggingStatus == .untagged }.sorted(by: byOrder)
            case .invalidTagging:
                return playlist.files.filter { !$0.isSkipped && $0.taggingStatus == .invalid }.sorted(by: byOrder)
            case .skipped:
                return playlist.files.filter(\.isSkipped).sorted(by: byOrder)
            }
        }

        // No service filter: playback order (playable files matching the persisted
        // tag filter) is exactly what the file list shows.
        return playlist.playbackSequence
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
