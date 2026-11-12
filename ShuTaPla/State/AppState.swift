//
//  AppState.swift
//  ShuTaPla
//
//  The main-actor runtime state object: it owns the `ModelContext`, the current
//  app mode, and the active-playlist references, and drives the folder-picker →
//  scan → playlist-creation flow. Injected into the SwiftUI environment so every
//  view reads the same instance.
//
//  The orchestration is split across `AppState+<Concern>.swift` siblings (slots,
//  lifecycle, creation, rescan, file ops, playback, confirmations, filtering). This
//  file holds the shared observable state, `init`, and the cross-cutting persist/
//  fetch plumbing those siblings reach through. The `var` state below is mutated only
//  by this type's own methods (here and in the siblings), never by views; Swift's
//  file-scoped `private` can't express that across the split, so it reads as internal.
//

import Foundation
import SwiftData
import Observation
import AppKit

@MainActor
@Observable
final class AppState {

    let modelContext: ModelContext
    let fileSystem: FileSystemProviding

    /// The shared sequence provider: owns the memoized file-ID sequences and their version counter,
    /// injected into the coordinator so its engine-facing reads reuse the same cache the Manager and
    /// overlays derive against. `persistAndRefresh` bumps it after every persisted mutation.
    let sequences: PlaybackSequences

    /// Security-scoped folder access: the coordinator's per-playlist playback sessions and the
    /// file-edit flows' one-shot editing access, over one reference-counted `BookmarkService`.
    let folderAccess: ScopedFolderAccess

    /// The save `persistAndRefresh` performs — the model context's own `save` in production,
    /// injectable so a test can exercise the save-failure path (which the in-memory store
    /// otherwise never reaches).
    private let persist: () throws -> Void

    /// Drives actual playback: owns the engines, enforces channel exclusivity, and
    /// resolves file URLs through `bookmarkService`. Injected into the player views.
    let coordinator: PlaybackCoordinator

    /// The live iCloud/offline status feed: watches each live channel's folder and writes
    /// `cloudStatus` onto its files. Held by the coordinator (which drives its query lifecycle)
    /// and injected into the views that render the cloud indicator.
    let cloudFileService: CloudFileService

    /// The Manager "peek": shows one selected file on its own engine, outside the coordinator's
    /// channels, so it disturbs neither the playlist nor the live audio channel. Injected into
    /// the lightbox view; driven from `togglePreviewOfSelection()`.
    let preview: MediaPreview

    /// Player-mode overlay visibility. Owned here because a playlist switch from an overlay closes
    /// it and the Visual Overlay's visibility drives the coordinator's visual hold; injected into
    /// the views and `HotkeyRouter`.
    let overlays = OverlayManager()

    /// Runs the Update path's file reconciliation on its own `ModelContext` off the main actor,
    /// so a re-scan's O(N) derive/diff/write never blocks the UI. Built from the shared container.
    let scanActor: PlaylistScanActor

    let appStateModel: AppStateModel
    let globalSettings: GlobalSettings

    var mode: AppMode

    /// Which media type the sidebar lists — the Manager's scope. Persisted, so a relaunch reopens
    /// the scope that was being managed. Set through `switchScope(to:)` (the browse gesture) or
    /// `setManaged(_:)` (a managed playlist sets the scope to its type); the managed playlist always
    /// matches it.
    var managerScope: MediaType = .video

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

    /// The per-playlist exclusion between file ops, background tasks and a playlist delete.
    let playlistWork = PlaylistWorkGate()

    /// The most recently started background task of `trackBackgroundTask`, so tests can await it
    /// to completion.
    var updateTask: Task<Void, Never>?

    /// In-flight confirmation operations (delete / strip-audio / tag removal / playlist delete /
    /// move) launched from the modal confirm handlers and the folder chooser, keyed by a token so each retains itself until it
    /// finishes (and self-prunes). Retaining them keeps the SwiftData work from running as
    /// an un-owned fire-and-forget Task; `cancelConfirmationTasks()` tears them down.
    var confirmationTasks: [UUID: Task<Void, Never>] = [:]

    /// File-list selection in the Manager center panel, by file ID. Cleared when the managed
    /// playlist changes. One set: it belongs to the single managed playlist, whatever its type.
    /// The tag inspector reads this.
    var managerSelection: Set<UUID> = []

    /// The two transient Manager review modes — find-duplicates and skipped-review — each a
    /// runtime-only swap of the center sequence (never persisted), mutually exclusive. Set through
    /// `setDuplicateSearch` / `setSkippedReview`; both cleared by `exitReviewModes` on any filter
    /// edit, managed-playlist switch, or scope switch. Skipped-review lists the wrong-type files a
    /// scan flagged (delete / show-in-folder / rename only) — they are unplayable, never in the
    /// ordinary sequence.
    var duplicateSearchActive = false
    var skippedReviewActive = false

    /// Bumped by `manage` to ask the file list to scroll its selection into view,
    /// even when the selection itself didn't change — so re-clicking the current
    /// playlist re-centers the playing file. The list observes the change only.
    var scrollSelectionToken = 0

    /// The audio overlay's counterpart to `scrollSelectionToken`: bumped by
    /// `playOnAudioChannel` so the extended overlay's file list scrolls the current track
    /// into view when the live audio playlist is re-selected while the overlay is open.
    var audioScrollToken = 0

    /// The Observation gate the sidebar lists derive against — `sequences.version` for the playlist
    /// set. Bumped only by the mutations that change what a sidebar row shows: the playlist set
    /// itself (create / delete / rename / reorder) and the file create/delete paths, since the rows
    /// carry `fileCount`. Written through `notePlaylistsChanged()` alone.
    ///
    /// The sidebars derive from this rather than a live `@Query<Playlist>` because a mounted query
    /// refaults *every* registered instance of its entity on *any* store save — including the
    /// per-cell metadata fills and the ~5s `lastPosition` writes, neither of which changes a
    /// playlist. Since SwiftData hands the same instance to the query and to every view holding one
    /// directly, that refault re-fired per-keypath observation across the whole Manager chrome and
    /// made gallery scroll CPU-bound in AttributeGraph churn. A plain fetch refaults nothing
    /// (`PlaylistSnapshotRefaultTests`), so deriving on this narrow signal costs one small fetch per
    /// real change and wakes nothing in between.
    private(set) var playlistsVersion = 0

    /// The app-root modals, shown one at a time from the head (`WindowModals`). Living on
    /// `AppState` rather than in the raising view is what lets the `HotkeyRouter` see them, and keeps
    /// one on screen when the surface that raised it goes away: a confirmation's file op is async,
    /// and the Manager panel or the player overlay that raised it can be gone by the time it fails.
    private(set) var windowModals = WindowModals()

    /// Applies `change` to the modals, then shows the head when the window has no sheet.
    private func updateModals(_ change: (inout WindowModals) -> Void) {
        change(&windowModals)
        showHeadWithoutSheet()
    }

    /// Writes only on a change: every write re-renders the app root.
    private func showHeadWithoutSheet() {
        if !windowHasSheet, windowModals.canShowHead { windowModals.showHead() }
    }

    /// Whether the window has a sheet: the folder chooser, an alert, one still closing. Set by the
    /// `RootView` window bridge. SwiftUI drops a modal raised while a sheet is on the window and
    /// does not show it when that sheet ends, so the head of `windowModals` shows once the last
    /// sheet has ended.
    @ObservationIgnored var windowHasSheet = false {
        didSet { showHeadWithoutSheet() }
    }

    /// The one modal confirmation pending, if any (`nil` = none). Its case names the destructive
    /// family and carries its target. While it shows, the `HotkeyRouter` passes `[enter]`/`[esc]`
    /// to its default/cancel buttons and swallows every other key.
    var pendingConfirmation: PendingConfirmation? {
        get { windowModals.queue.lazy.compactMap(\.confirmation).first }
        set { updateModals { $0.set(.confirmation, to: newValue.map(WindowModal.confirmation)) } }
    }

    /// The first queued report that an operation failed or was refused; its title carries each
    /// site's wording.
    var errorNotice: ErrorNotice? { windowModals.queue.lazy.compactMap(\.report).first }

    /// Queues `notice` behind the modals already raised. A report equal to a queued one is skipped:
    /// a batch that saves per file reports a failing store once per file.
    func report(_ notice: ErrorNotice) {
        guard !windowModals.queue.contains(where: { $0.report == notice }) else { return }
        updateModals { $0.raise(.report(notice)) }
    }

    /// Removes the report on screen.
    func dismissErrorNotice() {
        updateModals { $0.removeShown(.report) }
    }

    /// The folder chooser's purpose, queued or shown (`nil` = none). Setting it raises the chooser;
    /// the shared `FolderPickFlow` modifier presents it. The panel runs out of process and owns its
    /// keys: the router passes every bare key through while it shows (`WindowModal.Kind.ownsKeys`).
    var folderPick: FolderPick? {
        get { windowModals.queue.lazy.compactMap(\.folderPick).first }
        set { updateModals { $0.set(.folderPick, to: newValue.map(WindowModal.folderPick)) } }
    }

    /// The folder the last move went to this session — where the next move's chooser starts.
    var lastMoveDestination: URL?

    /// A scanned Mixed folder awaiting the user's media-type choice. While non-nil the add
    /// flow's choice dialog owns the keyboard.
    var pendingTypeChoice: ScannedFolder? {
        get { windowModals.queue.lazy.compactMap(\.typeChoice).first }
        set { updateModals { $0.set(.typeChoice, to: newValue.map(WindowModal.typeChoice)) } }
    }

    /// True while a picked folder is being scanned into a playlist, so the add buttons can
    /// disable and show a spinner.
    var isAddingPlaylist = false

    /// Files under disk work (rename, tag edit, trash, move, audio removal), so their list/gallery rows can show a
    /// spinner while it runs. A quit waits until it is empty (`hasDiskWork`). Each visible row reads
    /// the whole set, as it reads `managerSelection`, so every write re-renders the visible rows: an op
    /// marks and unmarks its claimed files in one write each, and only an early release writes per
    /// file. The marks stay keyed by id: an op ends them after its
    /// re-scan await, when a claimed row can be pruned and must not be read (`withFileOp`).
    var busyFileIDs: Set<UUID> = [] {
        didSet { quitAfterWait() }
    }

    /// True while a quit waits for the disk work (`shouldTerminate`). While true the app-root
    /// alert lists it.
    var isWaitingToQuit: Bool {
        get { windowModals.queue.contains { $0.kind == .quitWait } }
        set { updateModals { $0.set(.quitWait, to: newValue ? .quitWait : nil) } }
    }

    /// Answers a held quit: `true` quits, `false` keeps the app open. A seam for tests, which
    /// record the reply in place of sending it.
    @ObservationIgnored var replyToTerminate: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// Folders currently being scanned into new playlists, shown in the sidebar as
    /// transient spinner rows so a large import gives immediate feedback.
    var importingPlaylists: [ImportingPlaylist] = []

    /// Re-scans in flight per playlist, so its sidebar row can show a spinner. A count: a superseded
    /// re-scan runs beside the one that replaced it (`trackBackgroundTask`), and the row stays busy
    /// until the last ends.
    var rescanCounts: [UUID: Int] = [:]

    /// Live column count of the Manager gallery grid, reported by `FileCollectionView`
    /// as it lays out, so keyboard navigation can step in 2D. The list is one column.
    var fileGridColumns: Int = 1

    init(
        modelContext: ModelContext,
        fileSystem: FileSystemProviding = FileSystemService(),
        bookmarkService: BookmarkService = BookmarkService(),
        cloudFileService: CloudFileService = CloudFileService(),
        persist: (() throws -> Void)? = nil,
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try VideoPlaybackEngine() }
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.persist = persist ?? { try modelContext.save() }
        self.appStateModel = AppStateModel.fetchOrCreate(in: modelContext)
        let settings = GlobalSettings.fetchOrCreate(in: modelContext)
        self.globalSettings = settings
        let folderAccess = ScopedFolderAccess(bookmarkService: bookmarkService)
        self.folderAccess = folderAccess
        self.cloudFileService = cloudFileService
        let sequences = PlaybackSequences(modelContext: modelContext)
        self.sequences = sequences
        self.coordinator = PlaybackCoordinator(
            folderAccess: folderAccess,
            globalSettings: settings,
            cloudFileService: cloudFileService,
            sequences: sequences,
            makeVideoEngine: makeVideoEngine
        )
        self.preview = MediaPreview(
            folderAccess: folderAccess, cloudFileService: cloudFileService, makeVideoEngine: makeVideoEngine
        )
        self.scanActor = PlaylistScanActor(modelContainer: modelContext.container)

        // Welcome until at least one playlist exists, otherwise Manager — unless a
        // visual playlist was playing at quit, in which case `reconstructPlayback`
        // reopens Player mode below.
        let existing = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        self.mode = existing.isEmpty ? .welcome : .manager

        // Saved at once, so the background re-scan's fetch sees the new bookmark and path. The save runs in
        // the middle of the opener's caller, so a failure keeps the context's pending edits (no
        // rollback): the caller's in-memory state already reflects them, and the next save retries.
        folderAccess.onBookmarkRefresh = { [weak self] in
            guard let self else { return }
            do { try self.persist() } catch { report(.saveFailed(error.localizedDescription)) }
        }

        coordinator.onLostFolder = { [weak self] in self?.report(.folderNotFound($0.name)) }
        playlistWork.onDeleteEnded = { [weak self] in self?.quitAfterWait() }
        overlays.onVisualOverlayChange = { [coordinator] in coordinator.setVisualHeld($0) }

        resolveActivePlaylists()
        reconstructPlayback()
    }

    // MARK: - Persist / fetch plumbing

    /// Saves pending changes and bumps the sequence version, so the store-side derivations (which
    /// ignore pending changes) see the change and re-derive. Mutation paths call this once they
    /// have reshaped file membership, order, tags, or triage/filter state — and before any
    /// coordinator reconcile/advance that re-derives a sequence.
    ///
    /// On a save failure the store keeps its pre-edit state while the context still holds the
    /// pending edit, so the store-side lists (`includePendingChanges: false`) would diverge from
    /// the model. The failure is therefore not swallowed: the context is rolled back — discarding
    /// the pending edit so a later successful save can't silently flush it — and the error is
    /// surfaced. The version still bumps so the store-side surfaces re-derive from the saved store.
    func persistAndRefresh() {
        persistChanges()
        sequences.bump()
    }

    /// The save half of `persistAndRefresh`, for a batch that must save each step and refreshes the
    /// store-side lists once at its end.
    func persistChanges() {
        do {
            try persist()
        } catch {
            modelContext.rollback()
            report(.saveFailed(error.localizedDescription))
        }
    }

    /// Bumps `playlistsVersion`. Called by the mutations that change which playlists exist, their
    /// order or label, or any playlist's file count — and by nothing else, since every extra bump
    /// re-renders both sidebar lists.
    func notePlaylistsChanged() {
        playlistsVersion &+= 1
    }

    /// The playlists of `mediaType` in section order — what the Manager sidebar renders, in place
    /// of a live `@Query<Playlist>` (see `playlistsVersion` for why there is no query).
    ///
    /// Reading the version here is the Observation dependency: the fetch itself registers none, so
    /// a body calling this re-runs exactly when a real playlist-set change bumps the version. That
    /// wakes the list body and re-diffs the set; a row's own `fileCount` needs the separate gate
    /// below, since a re-run body alone does not re-evaluate the rows.
    func playlists(ofType mediaType: MediaType) -> [Playlist] {
        _ = playlistsVersion
        return modelContext.playlists(ofType: mediaType)
    }

    /// The non-empty per-type groups of `types`' playlists, in the order of `types`; gated on the
    /// same version as `playlists(ofType:)`.
    func playlistSections(of types: [MediaType]) -> [PlaylistSection] {
        _ = playlistsVersion
        let byType = Dictionary(grouping: modelContext.playlistsInSectionOrder(), by: \.mediaType)
        return types.compactMap { type in
            byType[type].map { PlaylistSection(mediaType: type, playlists: $0) }
        }
    }

    /// A playlist's file count for its row badge, gated on the same version — `Playlist.fileCount`
    /// is likewise a `fetchCount` that registers nothing. Read by `PlaylistRowBadge`, which is a
    /// view of its own precisely so this gate is registered where the count is shown: a bump
    /// re-evaluates the enclosing list body, but not the rows (see the badge for why).
    func fileCount(of playlist: Playlist) -> Int {
        _ = playlistsVersion
        return playlist.fileCount
    }

    /// Resolves one identifier from a file sequence to its model, or nil if it no longer exists —
    /// the `ModelContext.file(for:)` fetch seam (a gone row drops to nil rather than an invalidated
    /// instance). A view realizing a row resolves only that row through here, so a large sequence is
    /// never materialized at once; one-shot action paths resolve just the rows they act on.
    func file(for id: PersistentIdentifier) -> PlaylistFile? {
        modelContext.file(for: id)
    }

    /// The row identity (`PersistentIdentifier`) of the file with app id `fileID`, or nil if none —
    /// the target a `List` scrolls to (a row's `ForEach` identity). A one-row fetch that faults no
    /// model, called only on a scroll request, never per row.
    func fileIdentifier(for fileID: UUID) -> PersistentIdentifier? {
        modelContext.identifier(of: fileID)
    }

    /// The selected manager files (the small selection set), resolved from the store in
    /// display order. Action paths that operate on the selection resolve only these rows, not
    /// the whole managed sequence. Not restricted to the effective filter — callers that need
    /// the *visible* selection intersect with `managerFileIDs`.
    func selectedManagerFiles() -> [PlaylistFile] {
        guard let playlist = managedPlaylist, managerSelection.isNotEmpty else { return [] }
        let pid = playlist.persistentModelID
        let ids = Array(managerSelection)
        var descriptor = FetchDescriptor<PlaylistFile>(
            predicate: #Predicate { $0.playlist?.persistentModelID == pid && ids.contains($0.id) },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        descriptor.includePendingChanges = false
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// The visible, selected manager files in display order — context-menu / batch-action
    /// targets. Resolves only the selection, then keeps those still in the effective filter.
    func visibleSelectedManagerFiles() -> [PlaylistFile] {
        let visible = Set(managerFileIDs)
        return selectedManagerFiles().filter { visible.contains($0.persistentModelID) }
    }

    /// How many selected files fell out of the effective filter — the selection minus its visible
    /// subset. The Manager preview's summary reads it to explain why an out-of-view file is still in
    /// the tag editor. Resolved through identifiers only (`fileIdentifier(for:)` and `managerFileIDs`,
    /// no object fetch), so reading it during a preview render can't refault a cell's just-merged
    /// metadata. Reads `managerSelection` and `managerFileIDs` (via `sequences.version`), so a view
    /// body that reads it re-renders when the selection or the filtered membership changes.
    var filteredOutSelectionCount: Int {
        let visible = Set(managerFileIDs)
        return managerSelection.compactMap { fileIdentifier(for: $0) }.filter { !visible.contains($0) }.count
    }

    /// Every content fingerprint across all files — the live keys the thumbnail cache's orphan
    /// sweep must keep. Files never thumbnailed carry no fingerprint and are skipped by the
    /// predicate; the set is what the sweep intersects against the `.heic` names. Pending changes
    /// are included (the default): the gallery merges a fingerprint onto a record on first display
    /// and lets autosave flush it, so a just-viewed file's key is live before it reaches the store —
    /// excluding pending changes here would sweep away the thumbnails of files shown this session.
    func liveThumbnailFingerprints() -> Set<String> {
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.fingerprint != nil })
        descriptor.propertiesToFetch = [\.fingerprint]
        let files = (try? modelContext.fetch(descriptor)) ?? []
        return Set(files.compactMap(\.fingerprint))
    }
}
