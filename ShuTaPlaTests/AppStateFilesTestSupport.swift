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
