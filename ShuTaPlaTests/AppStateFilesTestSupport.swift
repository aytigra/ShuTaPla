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
