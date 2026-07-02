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

    /// The Manager "peek": shows one selected file on its own engine, outside the coordinator's
    /// channels, so it disturbs neither the playlist nor the live audio channel. Injected into
    /// the lightbox view; driven from `togglePreviewOfSelection()`.
    let preview: MediaPreview

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

    /// In-flight background re-scans, keyed by playlist id, started by `rescan(_:)`. Keyed
    /// per playlist so re-reading one playlist supersedes only its own stale scan: selecting
    /// an audio playlist while a Manager visual re-scan is in flight leaves the visual scan
    /// running, rather than dropping it on the floor.
    var updateTasks: [UUID: Task<Void, Never>] = [:]

    /// The most recently started re-scan, so a delete can cancel it and tests can await it
    /// to completion. Points at whichever `rescan(_:)` ran last.
    var updateTask: Task<Void, Never>?

    /// In-flight confirmation operations (delete / strip-audio / tag removal) launched
    /// from the modal confirm handlers, keyed by a token so each retains itself until it
    /// finishes (and self-prunes). Retaining them keeps the SwiftData work from running as
    /// an un-owned fire-and-forget Task; `cancelConfirmationTasks()` tears them down.
    var confirmationTasks: [UUID: Task<Void, Never>] = [:]

    /// File-list selection in the Manager center panel, by file ID. Cleared when the managed
    /// playlist changes. One set: it belongs to the single managed playlist, whatever its type.
    /// The tag inspector reads this.
    var managerSelection: Set<UUID> = []

    /// Bumped by `manage` to ask the file list to scroll its selection into view,
    /// even when the selection itself didn't change — so re-clicking the current
    /// playlist re-centers the playing file. The list observes the change only.
    var scrollSelectionToken = 0

    /// The audio overlay's counterpart to `scrollSelectionToken`: bumped by
    /// `playOnAudioChannel` so the extended overlay's file list scrolls the current track
    /// into view when a playlist is (re-)selected while the overlay is already open.
    var audioScrollToken = 0

    /// Bumped after every persisted mutation that can change a file sequence's membership or
    /// order. The store-side identifier accessors (`managerFileIDs`, `visualChannelFileIDs`,
    /// `audioChannelFileIDs`) read it so SwiftUI re-derives them on the change: their fetches use
    /// `includePendingChanges: false` and aren't tracked by Observation on their own, unlike a
    /// walk over the `files` relationship would be.
    var sequenceVersion = 0

    /// A user-facing message when persisting a mutation fails. Set by `persistAndRefresh` when the
    /// save throws; the failed edit is rolled back so it can't be flushed by a later save, and the
    /// store-side lists re-derive from the unchanged saved store. Presented by the app-root alert.
    var saveError: String?

    /// The one modal confirmation currently pending, if any (`nil` = none). Its case names the
    /// destructive family and carries its target; at most one can be pending, enforced by the type.
    /// While non-nil the matching `.alert` host owns the keyboard: the `HotkeyRouter` passes
    /// `[enter]`/`[esc]` to its default/cancel buttons and swallows every other key.
    var pendingConfirmation: PendingConfirmation?

    /// A user-facing message when a confirmation's destructive work fails. One channel — only one
    /// confirmation runs at a time — presented once by the app-root `RootView` alert (where the
    /// audio overlay can't double-present it over the Manager panel); its title carries each
    /// family's wording.
    var confirmationError: ConfirmationError?

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
    var isAddingPlaylist = false

    /// Files whose audio is being removed, so their list/gallery rows can show a
    /// spinner while the remux runs.
    var strippingFileIDs: Set<UUID> = []

    /// A user-facing message when a rename from the Visual Overlay fails, surfaced by
    /// that overlay's alert. Not a confirmation outcome, so it stays its own channel; on
    /// `AppState` (not view-local) so the `HotkeyRouter` can register it as a blocking modal
    /// and stop bare keys leaking to playback behind it.
    var playerRenameError: String?

    /// A user-facing message when an extended-overlay audio rename fails — its own channel
    /// for the same reason as `playerRenameError`.
    var audioRenameError: String?

    /// Folders currently being scanned into new playlists, shown in the sidebar as
    /// transient spinner rows so a large import gives immediate feedback.
    var importingPlaylists: [ImportingPlaylist] = []

    /// IDs of existing playlists with a long-running operation in flight (e.g. a
    /// background re-scan), so their sidebar rows can show a spinner.
    var busyPlaylistIDs: Set<UUID> = []

    /// IDs of playlists currently being deleted (their files are being cleaned out
    /// in batches), so their sidebar rows can show a destructive red spinner.
    var deletingPlaylistIDs: Set<UUID> = []

    /// Live column count of the Manager gallery grid, reported by `FileGalleryView`
    /// as it lays out, so keyboard navigation can step in 2D. The list is one column.
    var fileGridColumns: Int = 1

    init(
        modelContext: ModelContext,
        fileSystem: FileSystemProviding = FileSystemService(),
        bookmarkService: BookmarkService = BookmarkService(),
        persist: (() throws -> Void)? = nil,
        makeVideoEngine: @escaping () throws -> MPVPlaybackEngine = { try VideoPlaybackEngine() }
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.persist = persist ?? { try modelContext.save() }
        self.appStateModel = AppStateModel.fetchOrCreate(in: modelContext)
        let settings = GlobalSettings.fetchOrCreate(in: modelContext)
        self.globalSettings = settings
        let folderAccess = ScopedFolderAccess(bookmarkService: bookmarkService, prompt: FolderReaccessPanel())
        self.folderAccess = folderAccess
        self.coordinator = PlaybackCoordinator(
            folderAccess: folderAccess,
            globalSettings: settings,
            makeVideoEngine: makeVideoEngine
        )
        self.preview = MediaPreview(folderAccess: folderAccess, makeVideoEngine: makeVideoEngine)
        self.scanActor = PlaylistScanActor(modelContainer: modelContext.container)

        // Welcome until at least one playlist exists, otherwise Manager — unless a
        // visual playlist was playing at quit, in which case `reconstructPlayback`
        // reopens Player mode below.
        let existing = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        self.mode = existing.isEmpty ? .welcome : .manager

        resolveActivePlaylists()
        reconstructPlayback()
    }

    // MARK: - Persist / fetch plumbing

    /// Saves pending changes and bumps `sequenceVersion`, so the store-side derivations (which
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
        do {
            try persist()
        } catch {
            modelContext.rollback()
            saveError = Self.saveErrorText(error.localizedDescription)
        }
        sequenceVersion &+= 1
    }

    /// The user-facing message the app-root alert presents for a save failure, wrapping the
    /// underlying error's description. Shared by the main-actor save path (`persistAndRefresh`)
    /// and the background reconcile path (`update`), which hands its failure back as a `String`.
    static func saveErrorText(_ detail: String) -> String {
        "Couldn’t save your changes: \(detail)"
    }

    /// Resolves one identifier from a file sequence to its model, or nil if it no longer exists.
    /// A view realizing a row resolves only that row through here, so a large sequence is never
    /// materialized at once; one-shot action paths resolve just the rows they act on.
    func file(for id: PersistentIdentifier) -> PlaylistFile? {
        modelContext.model(for: id) as? PlaylistFile
    }

    /// Whether `fileID` survives `playlist`'s effective display filter — a store-side membership
    /// test that resolves only that one file, rather than materializing the whole sequence.
    func displaySequenceContains(_ fileID: UUID, of playlist: Playlist) -> Bool {
        modelContext.displayMember(fileID, of: playlist) != nil
    }

    /// The selected manager files (the small selection set), resolved from the store in
    /// display order. Action paths that operate on the selection resolve only these rows, not
    /// the whole managed sequence. Not restricted to the effective filter — callers that need
    /// the *visible* selection intersect with `managerFileIDs`.
    func selectedManagerFiles() -> [PlaylistFile] {
        guard let playlist = managedPlaylist, !managerSelection.isEmpty else { return [] }
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
    func managerSelectionFiles() -> [PlaylistFile] {
        let visible = Set(managerFileIDs)
        return selectedManagerFiles().filter { visible.contains($0.persistentModelID) }
    }
}
