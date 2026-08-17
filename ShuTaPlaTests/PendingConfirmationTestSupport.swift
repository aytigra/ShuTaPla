//
//  PendingConfirmationTestSupport.swift
//  ShuTaPlaTests
//
//  Payload accessors for asserting on a pending confirmation. The app never needs them — it
//  presents the whole enum through one alert host, worded by the enum itself — but a test does,
//  to check that a request raised the right family against the right target. Keeping them here
//  rather than on the type keeps the assertions readable without production code no one calls.
//

import Foundation
@testable import ShuTaPla

extension PendingConfirmation {
    /// The Manager file-list selection this confirmation targets, or `nil` for other kinds.
    var managerDeleteFiles: [PlaylistFile]? {
        guard case .managerDelete(let files) = self else { return nil }
        return files
    }

    /// The visual-channel file this confirmation targets, or `nil` for other kinds.
    var playerDeleteFile: PlaylistFile? {
        guard case .playerDelete(let file) = self else { return nil }
        return file
    }

    /// The audio track this confirmation targets, or `nil` for other kinds.
    var audioDeleteFile: PlaylistFile? {
        guard case .audioDelete(let file) = self else { return nil }
        return file
    }

    /// The videos whose audio this confirmation would strip, or `nil` for other kinds.
    var audioStripFiles: [PlaylistFile]? {
        guard case .audioStrip(let files) = self else { return nil }
        return files
    }

    /// The playlist this confirmation would delete, or `nil` for other kinds.
    var playlistToDelete: Playlist? {
        guard case .playlistDelete(let playlist) = self else { return nil }
        return playlist
    }

    /// The saved search this confirmation would delete, or `nil` for other kinds.
    var savedSearchToDelete: SavedSearch? {
        guard case .savedSearchDelete(let search) = self else { return nil }
        return search
    }
}
