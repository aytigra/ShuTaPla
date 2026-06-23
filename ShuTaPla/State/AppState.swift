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

/// Which media type the Manager's sidebar lists. It decides which playlists you can pick
/// from to become the managed one — nothing more: not selection state, not a filter, not a
/// routing key. One-to-one with `MediaType`; switching it pre-loads that type's remembered
/// playlist into the managed slot.
enum ManagerScope: String {
    case image
    case video
    case audio

    init(_ mediaType: MediaType) {
        switch mediaType {
        case .image: self = .image
        case .video: self = .video
        case .audio: self = .audio
        }
    }

    var mediaType: MediaType {
        switch self {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        }
    }
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

    /// Which media type the sidebar lists. Persisted, so a relaunch reopens the scope that was
    /// being managed. Set through `switchScope(to:)` (the browse gesture) or `setManaged(_:)`
    /// (a managed playlist sets the scope to its type); the managed playlist always matches it.
    private(set) var managerScope: ManagerScope = .video

    /// The managed slot — the playlist the whole Manager view binds to (sidebar selection,
    /// center file list, filter bar, tag inspector). An independent reference, never reached
    /// *through* another slot: load steps set it. Its type always matches `managerScope`, or
    /// it is `nil` (the "select a playlist" placeholder).
    var managedPlaylist: Playlist?

    /// The audio channel slot — persistent: it survives Stop, so the transport can restart it,
    /// and it is what switching to audio scope loads into the managed slot. `nil` only before
    /// any audio playlist has been loaded (or after the loaded one is deleted).
    var audioChannelPlaylist: Playlist?

    // Per-type memory of the last-managed visual playlist, used only to pre-load the managed
    // slot when switching to that scope. Independent of each other (and of the mutually
    // exclusive *playing* visual channel, which lives on the coordinator).
    var lastManagedVideoPlaylist: Playlist?
    var lastManagedImagePlaylist: Playlist?

    /// In-flight background re-scans, keyed by playlist id, started by `rescan(_:)`. Keyed
    /// per playlist so re-reading one playlist supersedes only its own stale scan: selecting
    /// an audio playlist while a Manager visual re-scan is in flight leaves the visual scan
    /// running, rather than dropping it on the floor.
    private var updateTasks: [UUID: Task<Void, Never>] = [:]

    /// The most recently started re-scan, so a delete can cancel it and tests can await it
    /// to completion. Points at whichever `rescan(_:)` ran last.
    private(set) var updateTask: Task<Void, Never>?

    /// In-flight confirmation operations (delete / strip-audio / tag removal) launched
    /// from the modal confirm handlers, keyed by a token so each retains itself until it
    /// finishes (and self-prunes). Retaining them keeps the SwiftData work from running as
    /// an un-owned fire-and-forget Task; `cancelConfirmationTasks()` tears them down.
    private(set) var confirmationTasks: [UUID: Task<Void, Never>] = [:]

    /// File-list selection in the Manager center panel, by file ID. Cleared when the managed
    /// playlist changes. One set: it belongs to the single managed playlist, whatever its type.
    /// The tag inspector reads this.
    var managerSelection: Set<UUID> = []

    /// Bumped by `manage` to ask the file list to scroll its selection into view,
    /// even when the selection itself didn't change — so re-clicking the current
    /// playlist re-centers the playing file. The list observes the change only.
    private(set) var scrollSelectionToken = 0

    /// The audio overlay's counterpart to `scrollSelectionToken`: bumped by
    /// `playOnAudioChannel` so the extended overlay's file list scrolls the current track
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

    /// The audio channel playlist's files under its effective filter — the audio overlay's list.
    /// This is the *playback* sequence, so skipped tracks never appear: the audio overlay is a
    /// transport list (no triage toggles), and a track the engine won't play has no place in it.
    /// Under the Skipped filter the list is therefore empty. The service filter set in Manager
    /// still applies (e.g. Untagged narrows the channel to its untagged playable tracks).
    var audioChannelFiles: [PlaylistFile] { audioChannelPlaylist?.playbackSequence ?? [] }

    /// The visual channel playlist's display-ordered files — the Files & Tags overlay's list.
    /// This is the *display* sequence (it keeps skipped files under the Skipped filter), because
    /// the Files & Tags overlay is an editing surface where skipped rows are triaged and un-skipped.
    var visualChannelFiles: [PlaylistFile] { coordinator.liveVisualPlaylist?.displaySequence ?? [] }

    /// The audio channel's current track — the audio overlay's analog of `managerSelection`.
    /// Resolved from the playlist's persisted `currentFileID` against its file list, not the
    /// live engine, so it survives Stop: a stopped audio playlist still shows (and resumes from)
    /// where it left off. `nil` when the remembered file is filtered out of view.
    var currentAudioFile: PlaylistFile? { currentAudioFile(in: audioChannelFiles) }

    /// Resolves the audio channel's current track within an already-derived file list. A view
    /// that reads `audioChannelFiles` for its list passes that same list here instead of letting
    /// the accessor re-walk the whole sequence to look one file up.
    func currentAudioFile(in files: [PlaylistFile]) -> PlaylistFile? {
        guard let id = audioChannelPlaylist?.currentFileID else { return nil }
        return files.first { $0.id == id }
    }

    /// The visual channel's current file — the Files & Tags overlay's analog of
    /// `currentAudioFile`. Resolved from the playing playlist's persisted `currentFileID`
    /// against its file list, not the live engine, so it's available synchronously when
    /// the overlay's file list re-centers after a playlist switch (the video engine reports
    /// its current file asynchronously). `nil` when the remembered file is filtered out of view.
    var currentVisualFile: PlaylistFile? { currentVisualFile(in: visualChannelFiles) }

    /// Resolves the visual channel's current file within an already-derived file list, so a view
    /// holding `visualChannelFiles` need not re-walk the sequence to look one file up.
    func currentVisualFile(in files: [PlaylistFile]) -> PlaylistFile? {
        guard let id = coordinator.liveVisualPlaylist?.currentFileID else { return nil }
        return files.first { $0.id == id }
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
    }

    // MARK: - Slot references

    /// Restores the slot references and scope from the persisted IDs, then loads the
    /// persisted scope's remembered playlist into the managed slot.
    private func resolveActivePlaylists() {
        lastManagedVideoPlaylist = appStateModel.lastManagedVideoPlaylistId.flatMap(playlist(withID:))
        lastManagedImagePlaylist = appStateModel.lastManagedImagePlaylistId.flatMap(playlist(withID:))
        audioChannelPlaylist = appStateModel.audioChannelPlaylistId.flatMap(playlist(withID:))
        managerScope = appStateModel.managerScopeRaw.flatMap(ManagerScope.init(rawValue:)) ?? .video
        managedPlaylist = lastManagedPlaylist(for: managerScope)
    }

    private func playlist(withID id: UUID) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Records `playlist` as its type's remembered playlist, persisting the choice. The visual
    /// memories (video / image) are independent of each other; audio's memory is the channel
    /// slot itself. Touches neither the managed slot, the scope, nor playback.
    func rememberLastManaged(_ playlist: Playlist) {
        switch playlist.mediaType {
        case .video:
            lastManagedVideoPlaylist = playlist
            appStateModel.lastManagedVideoPlaylistId = playlist.id
        case .image:
            lastManagedImagePlaylist = playlist
            appStateModel.lastManagedImagePlaylistId = playlist.id
        case .audio:
            audioChannelPlaylist = playlist
            appStateModel.audioChannelPlaylistId = playlist.id
        }
    }

    /// The remembered playlist for a scope — what switching to it loads into the managed slot.
    private func lastManagedPlaylist(for scope: ManagerScope) -> Playlist? {
        switch scope {
        case .video: return lastManagedVideoPlaylist
        case .image: return lastManagedImagePlaylist
        case .audio: return audioChannelPlaylist
        }
    }

    /// Loads `playlist` into the managed slot: records it and sets the scope to its type, so the
    /// whole Manager binds to it. The one load step that makes a playlist managed; playback is a
    /// separate concern handled by the callers that start it.
    private func setManaged(_ playlist: Playlist) {
        rememberLastManaged(playlist)
        managedPlaylist = playlist
        managerScope = ManagerScope(playlist.mediaType)
        appStateModel.managerScopeRaw = managerScope.rawValue
    }

    /// The browse gesture: switches the sidebar to `scope` and pre-loads that scope's remembered
    /// playlist into the managed slot (possibly `nil` → the placeholder). Selection belongs to the
    /// managed playlist, so it clears and re-seeds on the new playlist's resume file.
    func switchScope(to scope: ManagerScope) {
        guard scope != managerScope else { return }
        managerScope = scope
        appStateModel.managerScopeRaw = scope.rawValue
        managedPlaylist = lastManagedPlaylist(for: scope)
        managerSelection = []
        if let playlist = managedPlaylist, let id = playlist.currentFileID,
           playlist.displaySequence.contains(where: { $0.id == id }) {
            managerSelection = [id]
        }
        scrollSelectionToken += 1
    }

    // MARK: - Manager accessors
    //
    // The Manager's center panel, filter bar, and tag inspector read these; all derive from
    // the single managed playlist, whatever its type.

    /// The managed playlist's display-ordered files under its effective filter.
    var managerFiles: [PlaylistFile] { managedPlaylist?.displaySequence ?? [] }

    /// The token the Manager center file list re-centers on (a re-select or scope switch).
    var managerScrollToken: Int { scrollSelectionToken }

    /// A double-click in the Manager center: a visual playlist enters the fullscreen player at
    /// the file; an audio playlist starts the audio channel there, staying in Manager.
    func playFromManager(of playlist: Playlist, startingAt file: PlaylistFile) {
        if playlist.mediaType == .audio {
            coordinator.play(playlist, startingAt: file)
        } else {
            startPlayback(of: playlist, startingAt: file)
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

        // Player-mode creation comes from a playback overlay (the visual Files & Tags or the
        // audio overlay) and starts the new playlist playing; Manager-mode creation loads it
        // stopped. A player-mode creation only *remembers* the playlist (so stopping back into
        // Manager returns to whatever was being managed), while a management creation loads it
        // into the managed slot and switches the scope to its type.
        let startsPlaying = mode == .player
        if startsPlaying {
            rememberLastManaged(playlist)
            coordinator.play(playlist)
        } else {
            // Only one audio playlist is ever live; releasing the channel keeps a background
            // playlist from playing on behind a stopped audio creation.
            if mediaType == .audio, let live = coordinator.liveAudioPlaylist { coordinator.stop(live) }
            setManaged(playlist)
            managerSelection = []
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
           playlist.displaySequence.contains(where: { $0.id == currentID }) {
            managerSelection = [currentID]
        }
        scrollSelectionToken += 1   // re-center even if the selection didn't change
        rescan(playlist)
    }

    /// Re-reads `playlist`'s folder on disk in the background — the automatic Update, the reason
    /// there's no dedicated control: re-clicking the open playlist re-scans and re-centers.
    /// Supersedes any in-flight re-scan of the *same* playlist so rapid clicks don't pile up,
    /// while leaving a different playlist's scan running. The spawned task is also remembered as
    /// `updateTask` so a delete can cancel it and tests can await it.
    private func rescan(_ playlist: Playlist) {
        updateTasks[playlist.id]?.cancel()
        let task = Task { await update(playlist) }
        updateTasks[playlist.id] = task
        updateTask = task
    }

    /// The visual Files & Tags overlay's analog of `playOnAudioChannel(_:)`: switches the
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
        rememberLastManaged(playlist)   // audioChannelPlaylist = playlist
        if isNewSelection { coordinator.play(playlist) }
        audioScrollToken += 1   // re-center the overlay file list on the current track
        rescan(playlist)
    }

    /// The audio inlet's Play when no audio playlist is active: start the first audio playlist
    /// if any exist, otherwise raise the add-folder flow to create one. (Once a playlist is
    /// active, the inlet shows the transport instead, whose Play continues that playlist.)
    func startFirstAudioPlaylistOrAdd() {
        if let first = modelContext.playlists(ofType: .audio).first {
            startPlayback(of: first)
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
        updateTasks[playlist.id]?.cancel()
        updateTasks[playlist.id] = nil
        // Release the playback channel first: a playing audio playlist (which runs even in
        // Manager mode) would otherwise leave the engine on files about to be deleted, and
        // its next advance would dereference a destroyed model.
        coordinator.stop(playlist)
        if managedPlaylist === playlist { managedPlaylist = nil }
        if lastManagedVideoPlaylist === playlist {
            lastManagedVideoPlaylist = nil
            appStateModel.lastManagedVideoPlaylistId = nil
        }
        if lastManagedImagePlaylist === playlist {
            lastManagedImagePlaylist = nil
            appStateModel.lastManagedImagePlaylistId = nil
        }
        if audioChannelPlaylist === playlist {
            audioChannelPlaylist = nil
            appStateModel.audioChannelPlaylistId = nil
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
        managerSelection.subtract(removedIDs)
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
        // A re-scan can drop either channel's playing file; advance off it just like a delete
        // does, so neither engine holds a file that's no longer in the playlist.
        coordinator.reconcile(playlistThatChanged: playlist)
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
            managerSelection.remove(file.id)
            file.playlist = nil
            modelContext.delete(file)
        }
        rebuildTagFrequency(playlist)
        // Advance whichever channel was playing this playlist off a trashed track, so the
        // engine never holds a file that's no longer in the playlist. Covers every delete
        // entry point (Manager list, Files & Tags overlay, audio overlay) in one place.
        coordinator.reconcile(playlistThatChanged: playlist)

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

    /// Starts a playlist playing through the coordinator. A visual playlist takes the window
    /// into Player mode and becomes the managed playlist; an audio playlist plays on its
    /// independent channel without changing mode or the managed (visual) slot.
    func startPlayback(of playlist: Playlist, startingAt file: PlaylistFile? = nil) {
        // Audio is an independent channel driven from its overlay/inlet, so starting it must
        // not disturb the managed visual playlist or the scope.
        if playlist.mediaType == .audio {
            rememberLastManaged(playlist)   // audioChannelPlaylist = playlist
            coordinator.play(playlist, startingAt: file)
            return
        }
        if managedPlaylist !== playlist { managerSelection = [] }
        setManaged(playlist)
        coordinator.play(playlist, startingAt: file)
        mode = .player
    }

    /// Plays the Manager file-list selection (the `[enter]` hotkey): begins playback of the
    /// managed playlist starting at the first selected file. Returns whether there was a
    /// selection to play, so the key only consumes when it acts.
    @discardableResult
    func playSelectedFile() -> Bool {
        guard let playlist = managedPlaylist,
              let file = managerFiles.first(where: { managerSelection.contains($0.id) }) else { return false }
        startPlayback(of: playlist, startingAt: file)
        return true
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

    /// Requests confirmation to trash the current file-list selection (Manager
    /// `[delete]`). Returns whether there was anything selected to delete.
    @discardableResult
    func requestDeleteSelectedFiles() -> Bool {
        let files = managerFiles.filter { managerSelection.contains($0.id) }
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
        performDelete(targets) { self.managerDeleteError = $0 }
    }

    /// Trashes `files` as a retained confirmation task — `deleteFiles` advances any live channel
    /// off them — routing the first failure message to `report`. The one place the trash + the
    /// post-delete error handling lives, shared by the Manager, Player, and audio confirmations.
    private func performDelete(_ files: [PlaylistFile], onError report: @escaping (String) -> Void) {
        guard !files.isEmpty else { return }
        // On failure (permissions/locked) `deleteFiles` trashes nothing, so its reconcile is a
        // no-op and the surface stays on the file; surface the message rather than silently
        // advancing past an undeleted file.
        runConfirmation { if let error = await self.deleteFiles(files) { report(error) } }
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
        performDelete([file]) { self.audioDeleteError = $0 }
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
        guard let tag = pendingTagRemoval, let playlist = managedPlaylist else {
            pendingTagRemoval = nil
            return
        }
        pendingTagRemoval = nil
        runConfirmation { if let error = await self.removeTagAcrossPlaylist(playlist, tag: tag) { self.tagRemovalError = error } }
    }

    /// Live column count of the Manager gallery grid, reported by `FileGalleryView`
    /// as it lays out, so keyboard navigation can step in 2D. The list is one column.
    var fileGridColumns: Int = 1

    /// Moves the Manager file-list selection one step in `direction` through `managerFiles`,
    /// collapsing any multi-selection to a single row. In list mode it is a vertical 1-D walk;
    /// in gallery mode left/right step by one and up/down step by a full row. Returns whether
    /// the key was consumed (so no system beep).
    @discardableResult
    func moveFileSelection(_ direction: MoveDirection) -> Bool {
        let files = managerFiles
        guard !files.isEmpty else { return false }

        let gallery = managedPlaylist?.preferences.viewMode == .gallery
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

        let selected = files.indices.filter { managerSelection.contains(files[$0].id) }
        if let edge = (step >= 0 ? selected.max() : selected.min()) {
            let target = edge + step
            // Stay within bounds; ignore a move that would fall off the grid (still
            // consumed, so the key never beeps).
            if target >= 0, target < files.count {
                managerSelection = [files[target].id]
            }
        } else {
            managerSelection = [files[step >= 0 ? 0 : files.count - 1].id]
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

    /// Requests confirmation to trash the audio channel's current track (the extended
    /// overlay's `[delete]`, when audio holds key context). Returns whether there was a
    /// track to delete. The visual `[delete]` analog is `requestDeletePlayingFile`.
    @discardableResult
    func requestDeletePlayingAudioFile() -> Bool {
        guard let file = currentAudioFile else { return false }
        audioDeleteCandidate = file
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
        performDelete([file]) { self.playerDeleteError = $0 }
    }

    /// Stops the visual playlist and returns the window to Manager mode (the pause overlay's
    /// Stop, the `[s]`/`[delete]`-after exits, and the Back control). Stopping the transient
    /// visual channel ejects its playlist into the managed slot, switching scope to its type.
    func stopAndExitPlayer() {
        let visual = coordinator.liveVisualPlaylist
        // Remember the file that was on screen so Manager reopens with it selected and
        // scrolled into view, rather than at the top.
        let lastFileID = coordinator.visualCurrentFile?.id
        if let visual { coordinator.stop(visual) }
        coordinator.unsuppress()
        playerDeleteCandidate = nil
        if let visual { setManaged(visual) }
        if let lastFileID { managerSelection = [lastFileID] }
        scrollSelectionToken += 1
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
        return error
    }

    /// Removes a tag from every file in the playlist that carries it.
    @discardableResult
    func removeTagAcrossPlaylist(_ playlist: Playlist, tag: String) async -> String? {
        let error = await editTags(playlist.files) { TagParser.removeTag(tag, from: $0) }
        removeTagFromFilters(playlist, tag: tag)
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
        return firstError
    }

    // MARK: - Filtering
    //
    // Each method edits the *given* playlist's persisted filter state — the tag filter and the
    // triage (service) filter alike — and the surfaces re-derive (they read the model). The one
    // explicit side effect is the live-channel reconcile: if the edited playlist is currently
    // playing and its playing file fell out of the filter, the engine is advanced to a match.

    /// Toggles a triage filter on `playlist`. Triage filters are mutually exclusive and, while
    /// set, override the tag filter.
    func toggleServiceFilter(_ filter: ServiceFilter, on playlist: Playlist) {
        playlist.filterState.serviceFilter = (playlist.filterState.serviceFilter == filter) ? nil : filter
        filterChanged(on: playlist)
    }

    /// Adds or removes a tag from `playlist`'s tag filter. Editing the tag filter clears any
    /// active triage filter.
    func toggleFilterTag(_ tag: String, on playlist: Playlist) {
        playlist.filterState.serviceFilter = nil
        var tags = playlist.filterState.selectedTags
        if let index = tags.firstIndex(where: { TagParser.sameTag($0, tag) }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        playlist.filterState.selectedTags = tags
        filterChanged(on: playlist)
    }

    /// Sets the AND/OR operator on `playlist`'s tag filter.
    func setFilterMode(_ mode: FilterMode, on playlist: Playlist) {
        playlist.filterState.filterMode = mode
        filterChanged(on: playlist)
    }

    /// Clears `playlist`'s tag filter.
    func clearTagFilter(on playlist: Playlist) {
        playlist.filterState.selectedTags = []
        filterChanged(on: playlist)
    }

    /// Remembers `playlist`'s current tag filter as a saved search (most-recent first, unique by
    /// tag set + operator, capped at 10). No-op when the filter is empty.
    func saveCurrentSearch(on playlist: Playlist) {
        guard !playlist.filterState.isEmpty else { return }
        promote(SavedSearch(tags: playlist.filterState.selectedTags, mode: playlist.filterState.filterMode), in: playlist)
    }

    /// Re-applies a saved search on `playlist` and moves it to the top of the recents.
    func applySavedSearch(_ search: SavedSearch, on playlist: Playlist) {
        playlist.filterState.serviceFilter = nil
        playlist.filterState.selectedTags = search.tags
        playlist.filterState.filterMode = search.mode
        promote(search, in: playlist)
        filterChanged(on: playlist)
    }

    /// Removes a saved search from `playlist`'s recents.
    func removeSavedSearch(_ search: SavedSearch, on playlist: Playlist) {
        playlist.savedSearches.removeAll { $0.matches(search) }
    }

    private func promote(_ search: SavedSearch, in playlist: Playlist) {
        var searches = playlist.savedSearches.filter { !$0.matches(search) }
        searches.insert(search, at: 0)
        playlist.savedSearches = Array(searches.prefix(10))
    }

    /// The one explicit effect of a filter edit (the derivation boundary): if `playlist` is on a
    /// live channel and its playing file fell out of the new filter, advance the engine to a file
    /// that still matches. Every other surface re-derives from the model on its own.
    private func filterChanged(on playlist: Playlist) {
        coordinator.reconcile(playlistThatChanged: playlist)
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
