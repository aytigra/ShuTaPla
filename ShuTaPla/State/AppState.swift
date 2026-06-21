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

/// A directional step for keyboard navigation of the Manager file grid.
enum MoveDirection {
    case up, down, left, right
}

/// Which library the Manager is browsing. The visual scope spans video + image
/// playlists (one shared channel); the audio scope is the independent audio channel.
/// Switching scope is a view switch only — it never starts, stops, or loads a channel,
/// and the two scopes' state never overwrite each other.
enum ManagerScope {
    case visual
    case audio
}

/// A scanned folder awaiting a media-type decision because no type dominated it
/// (a Mixed folder). The view presents the choice and calls back with the type.
struct PendingPlaylist {
    let name: String
    let bookmark: Data
    let folderPath: String
    let scan: ScanResult
}

extension PendingPlaylist {
    /// Media types present in the Mixed folder, ordered by frequency (most first) —
    /// the choices the type dialog offers.
    var typeChoices: [MediaType] {
        scan.counts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    /// A choice button's label: the type name with its file count, e.g. "Video (12)".
    func choiceLabel(for type: MediaType) -> String {
        "\(type.displayName) (\(scan.counts[type] ?? 0))"
    }
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

    let appStateModel: AppStateModel
    let globalSettings: GlobalSettings

    var mode: AppMode

    /// Which library the Manager center/sidebar/toolbar act on. Transient — the Manager
    /// always opens in the visual scope; it is never persisted. Flipping it re-routes the
    /// scoped accessors (`managerPlaylist`/`managerFiles`/`managerSelection`/`managerFilterMode`)
    /// without touching either scope's underlying state.
    var managerScope: ManagerScope = .visual {
        didSet {
            guard oldValue != managerScope else { return }
            // A service filter is runtime-only and scope-local; it doesn't carry across a
            // scope switch any more than across a playlist switch. Drop it and refresh both
            // cached lists so the newly shown scope reflects its own (unfiltered) state.
            activeServiceFilter = nil
            recomputeFilteredFiles()
            recomputeAudioFilteredFiles()
        }
    }

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

    /// In-flight confirmation operations (delete / strip-audio / tag removal) launched
    /// from the modal confirm handlers, keyed by a token so each retains itself until it
    /// finishes (and self-prunes). Retaining them keeps the SwiftData work from running as
    /// an un-owned fire-and-forget Task; `cancelConfirmationTasks()` tears them down.
    private(set) var confirmationTasks: [UUID: Task<Void, Never>] = [:]

    /// File-list selection in the Manager center panel, by file ID. Cleared when
    /// the selected playlist changes. The tag panel reads this.
    var selectedFileIDs: Set<UUID> = []

    /// The audio scope's file-list selection, parallel to `selectedFileIDs`. Kept
    /// separate so switching Manager scope never disturbs the other scope's selection;
    /// `managerSelection` routes to whichever the active scope owns.
    var audioSelectedFileIDs: Set<UUID> = []

    /// Bumped by `select` to ask the file list to scroll its selection into view,
    /// even when the selection itself didn't change — so re-clicking the current
    /// playlist re-centers the playing file. The list observes the change only.
    private(set) var scrollSelectionToken = 0

    /// The audio overlay's counterpart to `scrollSelectionToken`: bumped by
    /// `selectAudioPlaylist` so the extended overlay's file list scrolls the current track
    /// into view when a playlist is (re-)selected while the overlay is already open.
    private(set) var audioScrollToken = 0

    /// Files awaiting the Manager trash confirmation (raised by the `[delete]` hotkey or
    /// a row's Delete command). While non-empty the center panel shows the confirmation
    /// alert, which owns the keyboard: the `HotkeyRouter` passes `[enter]`/`[esc]` to its
    /// default/cancel buttons and swallows every other key.
    var pendingManagerDelete: [PlaylistFile] = []

    /// A user-facing message when a Manager trash confirmation fails, surfaced by the
    /// center panel's alert.
    var managerDeleteError: String?

    /// The playlist awaiting a delete confirmation in the sidebar. While non-nil the sidebar
    /// shows the confirmation dialog, which owns the keyboard: the `HotkeyRouter` passes
    /// `[enter]`/`[esc]` to its default/cancel buttons and swallows every other key (so a bare
    /// `[delete]` can't stack a second trash confirmation behind it).
    var pendingPlaylistDelete: Playlist?

    /// Raises the folder picker for adding a playlist. The Welcome screen and the sidebar's
    /// plus button both set this; the shared `AddPlaylistFlow` modifier presents the picker.
    var isImportingPlaylist = false

    /// A scanned Mixed folder awaiting the user's media-type choice. While non-nil the add
    /// flow shows the choice dialog, which owns the keyboard: the `HotkeyRouter` registers it
    /// as a blocking modal so bare keys don't leak to playback behind it.
    var pendingTypeChoice: PendingPlaylist?

    /// A user-facing message when adding a playlist fails (or the folder has no media),
    /// surfaced by the add flow's alert and registered with the `HotkeyRouter` as blocking.
    var addPlaylistError: String?

    /// True while a picked folder is being scanned into a playlist, so the add buttons can
    /// disable and show a spinner.
    private(set) var isAddingPlaylist = false

    /// Videos awaiting the remove-audio confirmation (raised by a row's Remove Audio
    /// command). While non-empty the center panel shows the confirmation alert, which
    /// owns the keyboard: the `HotkeyRouter` passes `[enter]`/`[esc]` to its
    /// default/cancel buttons and swallows every other key.
    var pendingAudioStrip: [PlaylistFile] = []

    /// A user-facing message when removing audio fails, surfaced by the center
    /// panel's alert.
    var audioStripError: String?

    /// Files whose audio is being removed, so their list/gallery rows can show a
    /// spinner while the remux runs.
    private(set) var strippingFileIDs: Set<UUID> = []

    /// The playlist tag awaiting a remove-from-all-files confirmation in the Manager
    /// tag-management panel. While non-nil the panel shows the confirmation alert, which
    /// owns the keyboard: the `HotkeyRouter` passes `[enter]`/`[esc]` to its default/cancel
    /// buttons and swallows every other key.
    var pendingTagRemoval: String?

    /// A user-facing message when a playlist-wide tag removal fails, surfaced by the
    /// tag-management panel's alert.
    var tagRemovalError: String?

    /// The file the Player-mode `[delete]` hotkey is asking to trash. While non-nil the
    /// player shows a confirmation alert, which owns the keyboard: the `HotkeyRouter` passes
    /// `[enter]`/`[esc]` to its default/cancel buttons and swallows every other key.
    var playerDeleteCandidate: PlaylistFile?

    /// A user-facing message when a Player-mode trash fails, surfaced by the player's alert.
    var playerDeleteError: String?

    /// A user-facing message when a rename from the Files & Tags overlay fails, surfaced by
    /// that overlay's alert. On `AppState` (not view-local) so the `HotkeyRouter` can register
    /// it as a blocking modal and stop bare keys leaking to playback behind it.
    var playerRenameError: String?

    /// The audio track the extended overlay is asking to trash. Kept separate from
    /// `playerDeleteCandidate` because the extended overlay spans Manager and Player mode,
    /// where the player's visual-file delete alert isn't mounted; its own confirmation
    /// (and the error/rename messages below) is presented from the extended overlay.
    var audioDeleteCandidate: PlaylistFile?

    /// A user-facing message when an extended-overlay audio trash or rename fails.
    var audioDeleteError: String?
    var audioRenameError: String?

    /// Active runtime-only service filter (Untagged / Invalid tagging / Skipped).
    /// While set it overrides the selected playlist's persisted tag filter; it is
    /// mutually exclusive and never persisted.
    private(set) var activeServiceFilter: ServiceFilter?

    /// The selected playlist's files after the active filter, sorted for display.
    /// Cached so the file list doesn't refilter on every redraw; recomputed when
    /// the selection, filter, service filter, or file set changes.
    private(set) var filteredFiles: [PlaylistFile] = []

    /// The active audio playlist's files after its tag filter, for the extended audio
    /// overlay's file list. Kept separate from `filteredFiles` because the audio channel
    /// is independent of the Manager's selected video/image playlist; audio has no
    /// service filters, so this is just the playback sequence.
    private(set) var audioFilteredFiles: [PlaylistFile] = []

    /// The active audio playlist's current track — the audio overlay's analog of the Manager's
    /// `selectedFileIDs`. Resolved from the playlist's persisted `currentFileID` against the
    /// filtered list, not the live engine, so it survives Stop: a stopped audio playlist still
    /// shows (and resumes from) where it left off. `nil` when the remembered file is filtered
    /// out of view, mirroring how the Manager drops the highlight in that case.
    var currentAudioFile: PlaylistFile? {
        guard let id = activeAudioPlaylist?.currentFileID else { return nil }
        return audioFilteredFiles.first { $0.id == id }
    }

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
        recomputeAudioFilteredFiles()
    }

    // MARK: - Active playlist references

    /// Restores runtime references from the persisted active-playlist IDs.
    private func resolveActivePlaylists() {
        activeVideoPlaylist = appStateModel.activeVideoPlaylistId.flatMap(playlist(withID:))
        activeImagePlaylist = appStateModel.activeImagePlaylistId.flatMap(playlist(withID:))
        activeAudioPlaylist = appStateModel.activeAudioPlaylistId.flatMap(playlist(withID:))
        // The Manager selection is only ever a video/image playlist; audio lives in the
        // extended overlay and never occupies the Manager center panel.
        selectedPlaylist = activeVideoPlaylist ?? activeImagePlaylist
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

    // MARK: - Manager scope routing
    //
    // The Manager's sidebar, center panel, filter bar, and tag inspector read and write
    // through these accessors so one set of views serves both scopes. Each routes to the
    // active scope's own slot, so the scopes stay fully parallel — reading or writing one
    // never touches the other.

    /// The playlist the Manager center panel shows for the active scope: the selected
    /// video/image playlist (visual) or the active audio playlist (audio).
    var managerPlaylist: Playlist? {
        switch managerScope {
        case .visual: return selectedPlaylist
        case .audio: return activeAudioPlaylist
        }
    }

    /// The active scope's filtered, display-ordered files.
    var managerFiles: [PlaylistFile] {
        switch managerScope {
        case .visual: return filteredFiles
        case .audio: return audioFilteredFiles
        }
    }

    /// The active scope's file-list selection.
    var managerSelection: Set<UUID> {
        get {
            switch managerScope {
            case .visual: return selectedFileIDs
            case .audio: return audioSelectedFileIDs
            }
        }
        set {
            switch managerScope {
            case .visual: selectedFileIDs = newValue
            case .audio: audioSelectedFileIDs = newValue
            }
        }
    }

    /// The active scope's scroll-to-selection token, so the shared center file list can
    /// re-center on whichever scope's (re-)selection bumped it.
    var managerScrollToken: Int {
        switch managerScope {
        case .visual: return scrollSelectionToken
        case .audio: return audioScrollToken
        }
    }

    /// The active scope's AND/OR tag-filter operator, delegating to the scope's own
    /// `filterMode` / `audioFilterMode` binding source.
    var managerFilterMode: FilterMode {
        get {
            switch managerScope {
            case .visual: return filterMode
            case .audio: return audioFilterMode
            }
        }
        set {
            switch managerScope {
            case .visual: filterMode = newValue
            case .audio: audioFilterMode = newValue
            }
        }
    }

    // The Manager's shared filter bar drives these through the active scope so one control
    // edits the visual or audio playlist's tag filter and saved searches without the view
    // knowing which scope is live.

    /// Adds/removes a tag from the active scope's tag filter.
    func managerToggleFilterTag(_ tag: String) {
        switch managerScope {
        case .visual: toggleFilterTag(tag)
        case .audio: toggleAudioFilterTag(tag)
        }
    }

    /// Clears the active scope's tag filter.
    func managerClearFilter() {
        switch managerScope {
        case .visual: clearTagFilter()
        case .audio: clearAudioFilter()
        }
    }

    /// Saves the active scope's current tag filter as a saved search.
    func managerSaveSearch() {
        switch managerScope {
        case .visual: saveCurrentSearch()
        case .audio: saveAudioSearch()
        }
    }

    /// Re-applies a saved search on the active scope.
    func managerApplySearch(_ search: SavedSearch) {
        switch managerScope {
        case .visual: applySavedSearch(search)
        case .audio: applyAudioSearch(search)
        }
    }

    /// Removes a saved search from the active scope's recents.
    func managerRemoveSearch(_ search: SavedSearch) {
        switch managerScope {
        case .visual: removeSavedSearch(search)
        case .audio: removeAudioSearch(search)
        }
    }

    /// A double-click in the Manager center: the visual scope enters the fullscreen player
    /// at the file; the audio scope starts the audio channel there, staying in Manager.
    func beginManagerPlayback(of playlist: Playlist, startingAt file: PlaylistFile) {
        switch managerScope {
        case .visual: beginPlayback(of: playlist, startingAt: file)
        case .audio: coordinator.play(playlist, startingAt: file)
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
        // Switch the Manager to the new playlist's scope and make it that scope's selection:
        // a visual playlist becomes `selectedPlaylist`, an audio playlist becomes the active
        // audio playlist (stopped — creation never starts playback).
        if mediaType == .audio {
            managerScope = .audio
            recomputeAudioFilteredFiles()
        } else {
            managerScope = .visual
            selectedPlaylist = playlist
            activeServiceFilter = nil
            recomputeFilteredFiles()
        }
        if mode == .welcome { mode = .manager }
        return playlist
    }

    /// Next sort order within a media type's sidebar section (appended last).
    private func nextSortOrder(for mediaType: MediaType) -> Int {
        modelContext.playlists(ofType: mediaType).count
    }

    // MARK: - Manager operations

    /// Makes `playlist` the Manager selection, activates it for its channel, and
    /// kicks off a background re-scan to pick up files added or removed on disk.
    func select(_ playlist: Playlist) {
        let isNewSelection = selectedPlaylist !== playlist
        if isNewSelection { selectedFileIDs = [] }
        selectedPlaylist = playlist
        activeServiceFilter = nil   // service filters don't carry across playlists
        activate(playlist)
        recomputeFilteredFiles()    // show the restored per-playlist filter at once
        // Highlight where playback will resume and scroll the list to it. Selecting
        // the already-current playlist snaps the highlight back to the playing file —
        // the one way to do so without leaving the playlist. Skipped only when the
        // resume file is filtered out (or none has played yet).
        if let currentID = playlist.currentFileID,
           filteredFiles.contains(where: { $0.id == currentID }) {
            selectedFileIDs = [currentID]
        }
        scrollSelectionToken += 1   // re-center even if the selection didn't change
        // Re-read the folder on every (re-)select — this is the automatic Update, the reason
        // there's no dedicated control: re-clicking the open playlist re-scans and re-centers.
        // An in-flight scan is cancelled first so rapid clicks don't pile up.
        updateTask?.cancel()
        updateTask = Task { await update(playlist) }
    }

    /// The extended audio overlay's analog of `select(_:)`: makes `playlist` the active audio
    /// playlist, restores its filter, and re-reads its folder (every click — the same automatic
    /// Update the Manager does). A genuinely new selection also starts it playing; re-selecting
    /// the active one re-scans and re-centers without restarting playback.
    func selectAudioPlaylist(_ playlist: Playlist) {
        let isNewSelection = activeAudioPlaylist !== playlist
        activate(playlist)
        recomputeAudioFilteredFiles()
        if isNewSelection { coordinator.play(playlist) }
        audioScrollToken += 1   // re-center the overlay file list on the current track
        updateTask?.cancel()
        updateTask = Task { await update(playlist) }
    }

    /// The Manager's analog of `selectAudioPlaylist(_:)` for the audio scope sidebar:
    /// makes `playlist` the active audio playlist and re-scans its folder, but — unlike the
    /// overlay's play-on-select — does **not** start playback. Choosing a *different* playlist
    /// stops whichever audio playlist is live, so only one is ever playing and the newly
    /// selected one becomes active and stopped. Re-selecting the active playlist re-scans and
    /// re-centers without disturbing its playback.
    func selectAudioInManager(_ playlist: Playlist) {
        let isNewSelection = activeAudioPlaylist !== playlist
        if isNewSelection {
            audioSelectedFileIDs = []
            // Only one audio playlist is ever live; releasing the channel here keeps a
            // background playlist from playing on behind the new selection.
            if let live = coordinator.audioPlaylist { coordinator.stop(live) }
        }
        activate(playlist)
        recomputeAudioFilteredFiles()
        // Highlight where playback would resume, mirroring the visual `select`. Skipped when
        // the resume file is filtered out of view (or none has played yet).
        if let currentID = playlist.currentFileID,
           audioFilteredFiles.contains(where: { $0.id == currentID }) {
            audioSelectedFileIDs = [currentID]
        }
        audioScrollToken += 1
        updateTask?.cancel()
        updateTask = Task { await update(playlist) }
    }

    /// The audio inlet's Play when no audio playlist is active: start the first audio playlist
    /// if any exist, otherwise raise the add-folder flow to create one. (Once a playlist is
    /// active, the inlet shows the transport instead, whose Play continues that playlist.)
    func startFirstAudioPlaylistOrAdd() {
        if let first = modelContext.playlists(ofType: .audio).first {
            beginPlayback(of: first)
        } else {
            isImportingPlaylist = true
        }
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
        // Release the playback channel first: a playing audio playlist (which runs even in
        // Manager mode) would otherwise leave the engine on files about to be deleted, and
        // its next advance would dereference a destroyed model.
        coordinator.stop(playlist)
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
        recomputeAudioFilteredFiles()
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

        refreshStaleBookmark(for: playlist)

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

    /// Re-creates and re-persists a playlist's folder bookmark when macOS reports it
    /// stale (the folder moved or was renamed), so scoped access survives the next
    /// launch. A no-op when the bookmark resolves cleanly or can't be re-created.
    private func refreshStaleBookmark(for playlist: Playlist) {
        guard let resolved = try? BookmarkService.resolve(playlist.folderBookmark), resolved.isStale,
              let refreshed = try? BookmarkService.makeBookmark(for: resolved.url) else { return }
        playlist.folderBookmark = refreshed
    }

    private func apply(_ delta: UpdateDelta, to playlist: Playlist) {
        guard !delta.added.isEmpty || !delta.removedRelativePaths.isEmpty else { return }

        let removed = Set(delta.removedRelativePaths)
        let toRemove = playlist.files.filter { removed.contains($0.relativePath) }
        // Drop pending references to these files before deleting the models, so a
        // delete confirmation raised over a file the re-scan just pruned can't act on
        // (and dereference) a destroyed model when the user confirms.
        let removedIDs = Set(toRemove.map(\.id))
        pendingManagerDelete.removeAll { removedIDs.contains($0.id) }
        pendingAudioStrip.removeAll { removedIDs.contains($0.id) }
        if let candidate = playerDeleteCandidate, removedIDs.contains(candidate.id) {
            playerDeleteCandidate = nil
        }
        if let candidate = audioDeleteCandidate, removedIDs.contains(candidate.id) {
            audioDeleteCandidate = nil
        }
        selectedFileIDs.subtract(removedIDs)
        audioSelectedFileIDs.subtract(removedIDs)
        // Derive the next sort order from the files that survive this delta, not from the
        // post-detach `playlist.files` — so a still-counted to-be-removed file can't lend
        // its `sortOrder` to a new file and collide, breaking stable playback ordering.
        var nextOrder = (playlist.files.filter { !removedIDs.contains($0.id) }.map(\.sortOrder).max() ?? -1) + 1
        for file in toRemove {
            file.playlist = nil  // detach so playlist.files updates synchronously
            modelContext.delete(file)
        }

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
        // A re-scan can drop the audio channel's playing track; advance off it just like a
        // delete does, so the engine never holds a file that's no longer in the playlist.
        if coordinator.audioPlaylist === playlist { coordinator.reconcileAudioSelection() }
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
        for (index, playlist) in modelContext.playlists(ofType: mediaType).enumerated() {
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
        let (tags, status) = TagParser.fields(for: finalName)
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
            audioSelectedFileIDs.remove(file.id)
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

    /// Removes the audio track from each video, remuxing it in place (the video
    /// stream is copied, not re-encoded). The original is moved to the Trash as a
    /// recoverable backup and the audio-free file takes its place; a video currently
    /// on screen is reloaded and resumed at its position. Returns a message when some
    /// files couldn't be processed.
    func stripAudio(from files: [PlaylistFile]) async -> String? {
        guard let playlist = files.first?.playlist else { return nil }
        guard let folderURL = beginFolderAccess(to: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }

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
        let onScreen = coordinator.visualCurrentFile?.id == file.id ? coordinator.visualPlaylist : nil
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
        // Audio is an independent channel managed in the extended overlay, so starting
        // it must not disturb the Manager's selected video/image playlist.
        if playlist.mediaType == .audio {
            activate(playlist)
            coordinator.play(playlist, startingAt: file)
            recomputeAudioFilteredFiles()
            return
        }
        if selectedPlaylist !== playlist { selectedFileIDs = [] }
        activate(playlist)
        selectedPlaylist = playlist
        activeServiceFilter = nil           // service filters don't carry across playlists
        recomputeFilteredFiles()            // so Manager and Files & Tags show this playlist
        coordinator.play(playlist, startingAt: file)
        mode = .player
    }

    /// Plays the Manager file-list selection (the `[enter]` hotkey): begins playback of
    /// the selected playlist starting at the first selected file. Returns whether there
    /// was a selection to play, so the key only consumes when it acts.
    @discardableResult
    func playSelectedFile() -> Bool {
        guard let playlist = selectedPlaylist,
              let file = filteredFiles.first(where: { selectedFileIDs.contains($0.id) }) else { return false }
        beginPlayback(of: playlist, startingAt: file)
        return true
    }

    /// Cancels a running background re-scan — the only cancellable Manager operation.
    /// Returns whether something was in flight (the Manager `[esc]` hotkey consumes the
    /// key either way).
    @discardableResult
    func cancelInProgressOperation() -> Bool {
        guard !busyPlaylistIDs.isEmpty else { return false }
        updateTask?.cancel()
        updateTask = nil
        return true
    }

    /// Requests confirmation to trash the current file-list selection (Manager
    /// `[delete]`). Returns whether there was anything selected to delete.
    @discardableResult
    func requestDeleteSelectedFiles() -> Bool {
        let files = filteredFiles.filter { selectedFileIDs.contains($0.id) }
        guard !files.isEmpty else { return false }
        pendingManagerDelete = files
        return true
    }

    /// Requests confirmation to trash a specific set of Manager files (a file row's
    /// Delete command). Routes through AppState so `pendingManagerDelete` stays state
    /// it owns and prunes when a re-scan removes a referenced file.
    func requestManagerDelete(_ files: [PlaylistFile]) {
        pendingManagerDelete = files
    }

    /// Dismisses the Manager trash confirmation without trashing anything.
    func cancelManagerDelete() {
        pendingManagerDelete = []
    }

    /// Trashes the files pending in the Manager confirmation, surfacing any failure
    /// through `managerDeleteError`.
    func confirmManagerDelete() {
        let targets = pendingManagerDelete
        pendingManagerDelete = []
        guard !targets.isEmpty else { return }
        runConfirmation { if let error = await self.deleteFiles(targets) { self.managerDeleteError = error } }
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

    /// Requests confirmation to trash an audio track from the extended overlay.
    func requestAudioDelete(_ file: PlaylistFile) {
        audioDeleteCandidate = file
    }

    /// Dismisses the extended-overlay trash confirmation without trashing anything.
    func cancelAudioDelete() {
        audioDeleteCandidate = nil
    }

    /// Trashes the track pending in the extended-overlay confirmation, surfacing any
    /// failure through `audioDeleteError`.
    func confirmAudioDelete() {
        guard let file = audioDeleteCandidate else { return }
        audioDeleteCandidate = nil
        runConfirmation {
            if let error = await self.deleteFiles([file]) {
                self.audioDeleteError = error
            } else {
                // Advance the audio channel off the trashed track (the visual confirmPlayerDelete
                // does the same with reconcileVisualSelection).
                self.coordinator.reconcileAudioSelection()
            }
        }
    }

    /// Requests confirmation to remove the audio track from a video-row's selection
    /// (its Remove Audio command, in Manager or the player overlay). Routes through
    /// AppState so `pendingAudioStrip` stays state it owns and prunes when a re-scan
    /// removes a referenced file.
    func requestAudioStrip(_ files: [PlaylistFile]) {
        pendingAudioStrip = files
    }

    /// Dismisses the remove-audio confirmation without changing anything.
    func cancelAudioStrip() {
        pendingAudioStrip = []
    }

    /// Removes the audio from the videos pending in the confirmation, surfacing any
    /// failure through `audioStripError`.
    func confirmAudioStrip() {
        let targets = pendingAudioStrip
        pendingAudioStrip = []
        guard !targets.isEmpty else { return }
        runConfirmation { if let error = await self.stripAudio(from: targets) { self.audioStripError = error } }
    }

    /// Dismisses the playlist-wide tag-removal confirmation without removing anything.
    func cancelTagRemoval() {
        pendingTagRemoval = nil
    }

    /// Removes the pending tag from every file in the selected playlist, surfacing any
    /// failure through `tagRemovalError`.
    func confirmTagRemoval() {
        guard let tag = pendingTagRemoval, let playlist = managerPlaylist else {
            pendingTagRemoval = nil
            return
        }
        pendingTagRemoval = nil
        runConfirmation { if let error = await self.removeTagAcrossPlaylist(playlist, tag: tag) { self.tagRemovalError = error } }
    }

    /// Live column count of the Manager gallery grid, reported by `FileGalleryView`
    /// as it lays out, so keyboard navigation can step in 2D. The list is one column.
    var fileGridColumns: Int = 1

    /// Moves the Manager file-list selection one step in `direction` through
    /// `filteredFiles`, collapsing any multi-selection to a single row. In list mode
    /// it is a vertical 1-D walk; in gallery mode left/right step by one and up/down
    /// step by a full row. Returns whether the key was consumed (so no system beep).
    @discardableResult
    func moveFileSelection(_ direction: MoveDirection) -> Bool {
        let files = filteredFiles
        guard !files.isEmpty else { return false }

        let gallery = selectedPlaylist?.preferences.viewMode == .gallery
        let columns = gallery ? max(1, fileGridColumns) : 1
        let step: Int
        switch direction {
        case .up: step = -columns
        case .down: step = columns
        case .left: step = gallery ? -1 : 0      // no horizontal axis in the list
        case .right: step = gallery ? 1 : 0
        }

        // A horizontal key in the single-column list has no axis to move along; consume
        // it (so it never beeps) without disturbing the selection.
        guard step != 0 else { return true }

        let selected = files.indices.filter { selectedFileIDs.contains(files[$0].id) }
        if let edge = (step >= 0 ? selected.max() : selected.min()) {
            let target = edge + step
            // Stay within bounds; ignore a move that would fall off the grid (still
            // consumed, so the key never beeps).
            if target >= 0, target < files.count {
                selectedFileIDs = [files[target].id]
            }
        } else {
            selectedFileIDs = [files[step >= 0 ? 0 : files.count - 1].id]
        }
        return true
    }

    /// Requests confirmation to trash the file currently playing on the visual channel
    /// (Player `[delete]`). Returns whether there was a file to delete.
    @discardableResult
    func requestDeletePlayingFile() -> Bool {
        guard let file = coordinator.visualCurrentFile else { return false }
        playerDeleteCandidate = file
        return true
    }

    /// Requests confirmation to trash a specific file from the Files & Tags overlay.
    /// Routes through AppState so `playerDeleteCandidate` stays state it owns and
    /// prunes when a re-scan removes the file.
    func requestPlayerDelete(_ file: PlaylistFile) {
        playerDeleteCandidate = file
    }

    /// Dismisses the Player delete confirmation without trashing anything.
    func cancelPlayerDelete() {
        playerDeleteCandidate = nil
    }

    /// Trashes the file pending in the Player delete confirmation and advances the
    /// player to the next still-available file in the playlist.
    func confirmPlayerDelete() {
        guard let file = playerDeleteCandidate else { return }
        playerDeleteCandidate = nil
        runConfirmation {
            if let error = await self.deleteFiles([file]) {
                // The trash failed (permissions/locked): keep the player on the file and
                // tell the user, rather than silently advancing past an undeleted file.
                self.playerDeleteError = error
            } else {
                self.coordinator.reconcileVisualSelection()
            }
        }
    }

    /// Stops the visual playlist and returns the window to Manager mode (the pause
    /// overlay's Stop, the `[s]`/`[delete]`-after exits, and the Back control).
    func stopAndExitPlayer() {
        let visual = coordinator.visualPlaylist
        // Remember the file that was on screen so Manager reopens with it selected and
        // scrolled into view, rather than at the top.
        let lastFileID = coordinator.visualCurrentFile?.id
        if let visual { coordinator.stop(visual) }
        coordinator.unsuppress()
        playerDeleteCandidate = nil
        if let visual {
            selectedPlaylist = visual
            recomputeFilteredFiles()
        }
        if let lastFileID { selectedFileIDs = [lastFileID] }
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

    /// Renames a tag across every file in the playlist that carries it. Renaming onto
    /// another existing tag (a different tag that differs only in spelling/casing) is
    /// refused with a message rather than silently merging the two.
    @discardableResult
    func renameTagAcrossPlaylist(_ playlist: Playlist, from oldTag: String, to newTag: String) async -> String? {
        // Check every file's tags, not just `tagFrequency` (which counts only non-skipped
        // files) — a target tag carried solely by a skipped/invalid file is still a tag the
        // rename would silently merge onto.
        let collides = playlist.files.contains { file in
            file.tags.contains { TagParser.sameTag($0, newTag) && !TagParser.sameTag($0, oldTag) }
        }
        if collides { return "A tag named “\(newTag)” already exists." }
        let error = await editTags(playlist.files) { TagParser.renameTag(from: oldTag, to: newTag, in: $0) }
        rewriteTagInFilters(playlist) { TagParser.sameTag($0, oldTag) ? newTag : $0 }
        recomputeIfSelected(playlist)
        return error
    }

    /// Removes a tag from every file in the playlist that carries it.
    @discardableResult
    func removeTagAcrossPlaylist(_ playlist: Playlist, tag: String) async -> String? {
        let error = await editTags(playlist.files) { TagParser.removeTag(tag, from: $0) }
        removeTagFromFilters(playlist, tag: tag)
        recomputeIfSelected(playlist)
        return error
    }

    /// Maps every tag in the playlist's active tag filter and its saved searches through
    /// `transform`, keeping filter state in step with a playlist-wide tag rename so the
    /// filter doesn't keep pointing at a tag that no longer exists on disk.
    private func rewriteTagInFilters(_ playlist: Playlist, _ transform: (String) -> String) {
        playlist.filterState.selectedTags = TagParser.dedupe(playlist.filterState.selectedTags.map(transform))
        playlist.savedSearches = playlist.savedSearches.map {
            SavedSearch(id: $0.id, tags: TagParser.dedupe($0.tags.map(transform)), mode: $0.mode)
        }
    }

    /// Drops `tag` from the playlist's active tag filter and its saved searches after a
    /// playlist-wide removal. A saved search left with no tags is discarded.
    private func removeTagFromFilters(_ playlist: Playlist, tag: String) {
        playlist.filterState.selectedTags.removeAll { TagParser.sameTag($0, tag) }
        playlist.savedSearches = playlist.savedSearches.compactMap {
            let tags = $0.tags.filter { !TagParser.sameTag($0, tag) }
            return tags.isEmpty ? nil : SavedSearch(id: $0.id, tags: tags, mode: $0.mode)
        }
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
        switch managerScope {
        case .visual: filterDidChange()
        case .audio: audioFilterDidChange()
        }
    }

    /// Adds or removes a tag from the selected playlist's tag filter. Editing the
    /// tag filter clears any active service filter.
    func toggleFilterTag(_ tag: String) {
        guard let playlist = selectedPlaylist else { return }
        activeServiceFilter = nil
        var tags = playlist.filterState.selectedTags
        if let index = tags.firstIndex(where: { TagParser.sameTag($0, tag) }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        playlist.filterState.selectedTags = tags
        filterDidChange()
    }

    /// The selected playlist's AND/OR filter operator, as one binding source for the
    /// mode picker: the read and the write both run through here (the write recomputes
    /// the filtered files), so the control can't display one value while writing another.
    var filterMode: FilterMode {
        get { selectedPlaylist?.filterState.filterMode ?? .and }
        set { setFilterMode(newValue) }
    }

    /// Sets the AND/OR operator on the selected playlist's tag filter.
    func setFilterMode(_ mode: FilterMode) {
        guard let playlist = selectedPlaylist else { return }
        playlist.filterState.filterMode = mode
        filterDidChange()
    }

    /// Clears the selected playlist's tag filter.
    func clearTagFilter() {
        guard let playlist = selectedPlaylist else { return }
        playlist.filterState.selectedTags = []
        filterDidChange()
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
        filterDidChange()
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

    // MARK: - Audio overlay filter
    //
    // The extended audio overlay filters the active audio playlist independently of the
    // Manager's selected video/image playlist. Audio has no service filters, so these
    // edit the playlist's persisted tag filter directly, refresh `audioFilteredFiles`,
    // and keep playback on a track that still matches.

    /// The active audio playlist's AND/OR filter operator, as one binding source.
    var audioFilterMode: FilterMode {
        get { activeAudioPlaylist?.filterState.filterMode ?? .and }
        set {
            guard let playlist = activeAudioPlaylist else { return }
            playlist.filterState.filterMode = newValue
            audioFilterDidChange()
        }
    }

    /// Adds or removes a tag from the active audio playlist's tag filter.
    func toggleAudioFilterTag(_ tag: String) {
        guard let playlist = activeAudioPlaylist else { return }
        var tags = playlist.filterState.selectedTags
        if let index = tags.firstIndex(where: { TagParser.sameTag($0, tag) }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        playlist.filterState.selectedTags = tags
        audioFilterDidChange()
    }

    /// Clears the active audio playlist's tag filter.
    func clearAudioFilter() {
        guard let playlist = activeAudioPlaylist else { return }
        playlist.filterState.selectedTags = []
        audioFilterDidChange()
    }

    /// Remembers the active audio playlist's current tag filter as a saved search.
    func saveAudioSearch() {
        guard let playlist = activeAudioPlaylist, !playlist.filterState.isEmpty else { return }
        promote(SavedSearch(tags: playlist.filterState.selectedTags, mode: playlist.filterState.filterMode), in: playlist)
    }

    /// Re-applies a saved search on the active audio playlist, moving it to the top.
    func applyAudioSearch(_ search: SavedSearch) {
        guard let playlist = activeAudioPlaylist else { return }
        playlist.filterState.selectedTags = search.tags
        playlist.filterState.filterMode = search.mode
        promote(search, in: playlist)
        audioFilterDidChange()
    }

    /// Removes a saved search from the active audio playlist's recents.
    func removeAudioSearch(_ search: SavedSearch) {
        activeAudioPlaylist?.savedSearches.removeAll { $0.matches(search) }
    }

    /// Shared epilogue for audio filter mutations: refresh the cached list and keep the
    /// playing track on a file that still matches (jumping to the first match if not).
    private func audioFilterDidChange() {
        recomputeAudioFilteredFiles()
        coordinator.reconcileAudioSelection()
    }

    /// Recomputes `filteredFiles` for the current selection and active filter.
    func recomputeFilteredFiles() {
        guard let playlist = selectedPlaylist else { filteredFiles = []; return }
        filteredFiles = computeFilteredFiles(for: playlist, applyingServiceFilter: managerScope == .visual)
    }

    private func recomputeIfSelected(_ playlist: Playlist) {
        if playlist === selectedPlaylist { recomputeFilteredFiles() }
        if playlist === activeAudioPlaylist { recomputeAudioFilteredFiles() }
    }

    /// Recomputes `audioFilteredFiles` for the active audio playlist and its tag filter.
    /// In the audio scope a service filter (from the center notices) overrides the tag
    /// filter, exactly as it does for the visual scope; the player overlay's audio list
    /// (visual scope) only ever shows the tag-filtered playback sequence.
    func recomputeAudioFilteredFiles() {
        guard let playlist = activeAudioPlaylist else { audioFilteredFiles = []; return }
        audioFilteredFiles = computeFilteredFiles(for: playlist, applyingServiceFilter: managerScope == .audio)
    }

    /// Shared epilogue for tag/service filter mutations: refresh the cached file
    /// list and, in Player mode, keep the player on a file that still matches.
    private func filterDidChange() {
        recomputeFilteredFiles()
        reconcilePlayerSelection()
    }

    /// After a filter change in Player mode, keeps the player on a file that still
    /// matches: if the playing file was filtered out, the coordinator jumps to the
    /// first remaining file (or none, leaving the player on a placeholder).
    private func reconcilePlayerSelection() {
        if mode == .player { coordinator.reconcileVisualSelection() }
    }

    private func computeFilteredFiles(for playlist: Playlist, applyingServiceFilter: Bool) -> [PlaylistFile] {
        // A service filter, while active, replaces the tag filter entirely — but only for
        // the scope it belongs to, so the other scope's cached list keeps its tag filter.
        if applyingServiceFilter, let service = activeServiceFilter {
            return playlist.files(matching: service)
        }

        // No service filter: playback order (playable files matching the persisted
        // tag filter) is exactly what the file list shows.
        return playlist.playbackSequence
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
