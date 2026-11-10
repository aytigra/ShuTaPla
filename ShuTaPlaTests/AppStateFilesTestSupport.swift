//
//  AppStateFilesTestSupport.swift
//  ShuTaPlaTests
//
//  Test-only resolved views of the production identifier sequences. The app exposes the
//  Manager and overlay file lists as `[PersistentIdentifier]` (`managerFileIDs` and friends)
//  and resolves only the on-screen rows through `file(for:)`, so a large playlist never
//  materializes at once. The parity tests assert on filenames and order, so they resolve the
//  whole sequence here — a convenience that belongs to the tests, not the app.
//

import Foundation
import SwiftData
import Testing
@testable import ShuTaPla

extension AppState {
    var managerFiles: [PlaylistFile] { managerFileIDs.compactMap(file(for:)) }
    var audioChannelFiles: [PlaylistFile] { audioChannelFileIDs.compactMap(file(for:)) }
    var visualChannelFiles: [PlaylistFile] { visualChannelFileIDs.compactMap(file(for:)) }
}

/// A window-free (`vo=null`) engine that records the seek commands it receives instead of
/// touching mpv, so a test can assert exactly what a preview forwarded (or that nothing did).
@MainActor
final class RecordingSeekEngine: MPVPlaybackEngine {
    private(set) var seekByDeltas: [TimeInterval] = []
    private(set) var seekToPositions: [TimeInterval] = []
    init() throws { try super.init(configuration: .audio) }
    override func seek(by delta: TimeInterval) { seekByDeltas.append(delta) }
    override func seek(to seconds: TimeInterval) { seekToPositions.append(seconds) }
}

/// Constructs a `PlaylistFile`, attaches it to `playlist`, inserts it, and assigns its tags —
/// the build + insert + `tags(named:)` core the suites share. It does **not** save: the
/// store-side derivations ignore pending changes, so a caller that then derives a sequence
/// must save first. Suites differ in when (per file vs once after seeding a batch), so the
/// save stays with the caller.
@MainActor
@discardableResult
func insertFile(
    _ name: String,
    tags: [String] = [],
    status: TaggingStatus = .untagged,
    skipped: Bool = false,
    order: Int,
    to playlist: Playlist,
    in context: ModelContext
) -> PlaylistFile {
    let file = PlaylistFile(
        relativePath: name, fileName: name,
        taggingStatus: status, isSkipped: skipped, sortOrder: order
    )
    file.playlist = playlist
    context.insert(file)
    file.tags = context.tags(named: tags)
    return file
}

/// Leaves `playlist` unfiltered as `AppState.apply(nil, to:)` does — an ad-hoc filter is
/// unreachable the moment it stops being applied and goes with the clear, while one a search was
/// saved over stays reachable through the search. Suites filter and re-filter through these
/// repeatedly, and without the delete the fixtures would fill with `TagFilter` rows the model says
/// must never exist.
@MainActor
func clearTagFilter(on playlist: Playlist, in context: ModelContext) {
    let outgoing = playlist.currentFilter
    playlist.currentFilter = nil
    if let outgoing, outgoing.savedSearch == nil { context.delete(outgoing) }
}

/// Applies a tag filter to `playlist`: builds the row, inserts it, and points `currentFilter` at it,
/// clearing the outgoing one first. Like `insertFile` it does **not** save — the store-side
/// derivations ignore pending changes, so a caller that then derives a sequence must save first.
@MainActor
@discardableResult
func applyTagFilter(
    to playlist: Playlist,
    in context: ModelContext,
    mustHaveAll: [String] = [],
    mustHaveAny: [String] = [],
    mustNotHaveAll: [String] = [],
    mustNotHaveAny: [String] = []
) -> TagFilter {
    let filter = TagFilter()
    filter.mustHaveAll = mustHaveAll
    filter.mustHaveAny = mustHaveAny
    filter.mustNotHaveAll = mustNotHaveAll
    filter.mustNotHaveAny = mustNotHaveAny
    clearTagFilter(on: playlist, in: context)
    context.insert(filter)
    playlist.currentFilter = filter
    return filter
}

/// A main-actor callback that runs *inside* an in-flight `trashFiles`/`moveFiles`/`renameFile`, so a test can move
/// playback across the disk op's `await` the way a slideshow or end-of-file advance does, or observe
/// state while it runs. A box rather than a plain closure because the action usually needs the
/// `AppState` the stub is handed to.
@MainActor
final class DiskOpHook {
    var action: (() async -> Void)?

    func run() async { await action?() }
}

/// A tracked re-scan of `playlist` that ignores its cancellation and ends only when `open()` runs —
/// a scan past its commit decision, which still applies after a cancel. With a `listing`, it then
/// reconciles the playlist against it and commits; without one, it touches no model.
@MainActor
final class HeldScan {
    private(set) var ended = false
    private var isOpen = false
    private var gate: CheckedContinuation<Void, Never>?

    init(on playlist: Playlist, _ appState: AppState, committing listing: [ScannedFile]? = nil) {
        appState.trackBackgroundTask(for: playlist.id) { [self] in
            if !isOpen { await withCheckedContinuation { gate = $0 } }
            // An unstructured task, so the cancellation does not reach the reconcile's commit check.
            if let listing { await Task { await appState.deriveInBackground(playlist, from: listing) }.value }
            ended = true
        }
    }

    func open() {
        isOpen = true
        gate?.resume()
        gate = nil
    }
}

/// The folder a `StubFileSystem` lists on `rescan`. Its trash, move and rename change the listing,
/// as the disk would. While `holdsListings` is set, a `rescan` takes its snapshot and then waits
/// until `releaseListings()` or the rescan's cancellation — a scan that listed the folder and has
/// not yet reconciled.
@MainActor
final class StubFolder {
    var files: [ScannedFile]
    var holdsListings = false
    /// Listings taken and now waiting for release.
    private(set) var heldListings = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ files: [ScannedFile]) { self.files = files }

    func list() async -> [ScannedFile] {
        let snapshot = files
        guard holdsListings else { return snapshot }
        heldListings += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append($0) }
        } onCancel: {
            Task { @MainActor in self.releaseListings() }
        }
        return snapshot
    }

    func releaseListings() {
        holdsListings = false
        heldListings = 0
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func remove(_ urls: [URL]) {
        let names = Set(urls.map(\.lastPathComponent))
        files.removeAll { names.contains($0.fileName) }
    }

    func rename(_ url: URL, to newName: String) {
        files = files.map { $0.fileName == url.lastPathComponent ? scanned(newName, $0.mediaType) : $0 }
    }
}

/// Returns a canned scan result regardless of the bookmark it's handed, and a canned listing of
/// the folder's current files for re-scans (the reconcile infers removals by diffing it against
/// the playlist's own files).
struct StubFileSystem: FileSystemProviding {
    let result: ScanResult
    var rescanResult: [ScannedFile] = []
    /// When set, runs before `trashFiles` returns.
    var whileTrashing: DiskOpHook?
    /// When set, `trashFiles` reports every URL as failed (a locked/permission-denied trash).
    var trashFails = false
    /// When set, runs before `moveFiles` returns.
    var whileMoving: DiskOpHook?
    /// When set, `moveFiles` reports every URL as failed (a name collision at the destination).
    var moveFails = false
    /// When set, `rescan` throws — the "folder unreadable, leave membership as it was" path, for
    /// tests that exercise a re-scan's side effects without it reconciling files away.
    var rescanFails = false
    /// When set, `renameFile` throws it — exercises the failure-message mapping.
    var renameError: FileSystemError?
    /// File names whose `renameFile` fails (a locked file among renames that succeed).
    var renameFailsFor: Set<String> = []
    /// When set, runs before `renameFile` returns.
    var whileRenaming: DiskOpHook?
    /// When set, `rescan` lists it in place of `rescanResult`, and the trash, move and rename change it.
    var folder: StubFolder?
    /// When set, runs before `rescan` lists or throws.
    var whileRescanning: DiskOpHook?

    func scanFolder(bookmark: Data) async throws -> ScanResult { result }
    func rescan(bookmark: Data) async throws -> [ScannedFile] {
        await whileRescanning?.run()
        if rescanFails { throw FileSystemError.operationFailed("folder unreadable") }
        if let folder { return await folder.list() }
        return rescanResult
    }
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        await whileRenaming?.run()
        if let renameError { throw renameError }
        if renameFailsFor.contains(url.lastPathComponent) { throw FileSystemError.operationFailed("locked") }
        folder?.rename(url, to: newName)
        return url.deletingLastPathComponent().appendingPathComponent(newName)
    }
    func trashFiles(_ urls: [URL]) async -> FileBatchResult {
        await whileTrashing?.run()
        if !trashFails { folder?.remove(urls) }
        return FileBatchResult(urls, allFail: trashFails)
    }
    func moveFiles(_ urls: [URL], to folder: URL) async -> FileBatchResult {
        await whileMoving?.run()
        if !moveFails { self.folder?.remove(urls) }
        return FileBatchResult(urls, allFail: moveFails)
    }
}

extension FileBatchResult {
    /// Every URL succeeded, or every URL failed with the first file's cause, as the real service
    /// gives it.
    init(_ urls: [URL], allFail: Bool) {
        self.init(
            succeeded: allFail ? [] : urls, failed: allFail ? urls : [],
            firstError: allFail ? urls.first.map { "\($0.lastPathComponent) is locked." } : nil
        )
    }
}

/// A scan that found nothing — the stub result for the suites that drive `AppState` without
/// caring what the folder holds.
let emptyResult = ScanResult(files: [], counts: [:], dominantType: nil)

/// A `ScannedFile` for `name`, with the tags/status the parser derives from it — the seed the
/// scan and re-scan stubs hand back.
func scanned(_ name: String, _ type: MediaType) -> ScannedFile {
    let (tagNames, taggingStatus) = TagParser.fields(for: name)
    return ScannedFile(
        relativePath: name, fileName: name, mediaType: type, cloudStatus: .local,
        fileSize: nil, contentModified: nil, tagNames: tagNames, taggingStatus: taggingStatus
    )
}

/// Yields the main actor until `condition` holds, so a test can observe work that runs in an
/// unretained or in-flight Task.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    var spins = 0
    while !condition() {
        spins += 1
        try #require(spins < 100_000)
        await Task.yield()
    }
}

/// A fresh real directory under the temp dir — a bookmark needs a URL that exists.
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShuTaPlaTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
