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

/// Applies a tag filter to `playlist`: builds the row, inserts it, and points `currentFilter` at
/// it. Like `insertFile` it does **not** save — the store-side derivations ignore pending changes,
/// so a caller that then derives a sequence must save first.
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
    context.insert(filter)
    playlist.currentFilter = filter
    return filter
}

/// A main-actor callback that runs *inside* an in-flight `trashFiles`, so a test can move playback
/// across the delete's `await` the way a slideshow or end-of-file advance does. A box rather than a
/// plain closure because the action usually needs the `AppState` the stub is handed to.
@MainActor
final class TrashHook {
    var action: (() -> Void)?
}

/// Returns a canned scan result regardless of the bookmark it's handed, and a canned listing of
/// the folder's current files for re-scans (the reconcile infers removals by diffing it against
/// the playlist's own files).
struct StubFileSystem: FileSystemProviding {
    let result: ScanResult
    var rescanResult: [ScannedFile] = []
    /// When set, runs before `trashFiles` returns.
    var whileTrashing: TrashHook?
    /// When set, `trashFiles` reports every URL as failed (a locked/permission-denied trash).
    var trashFails = false
    /// When set, `rescan` throws — the "folder unreadable, leave membership as it was" path, for
    /// tests that exercise a re-scan's side effects without it reconciling files away.
    var rescanFails = false
    /// When set, `renameFile` throws it — exercises the failure-message mapping.
    var renameError: FileSystemError?

    func scanFolder(bookmark: Data) async throws -> ScanResult { result }
    func rescan(bookmark: Data) async throws -> [ScannedFile] {
        if rescanFails { throw FileSystemError.operationFailed("folder unreadable") }
        return rescanResult
    }
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        if let renameError { throw renameError }
        return url.deletingLastPathComponent().appendingPathComponent(newName)
    }
    func trashFiles(_ urls: [URL]) async throws -> TrashResult {
        if let whileTrashing { await MainActor.run { whileTrashing.action?() } }
        return trashFails ? TrashResult(trashed: [], failed: urls) : TrashResult(trashed: urls, failed: [])
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

/// A fresh real directory under the temp dir — a bookmark needs a URL that exists.
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShuTaPlaTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
