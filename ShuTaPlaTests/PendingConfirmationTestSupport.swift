//
//  PendingConfirmationTestSupport.swift
//  ShuTaPlaTests
//
//  Payload accessors for asserting on a pending confirmation or folder pick. The app never needs them — it
//  presents the whole enum through one alert host, worded by the enum itself — but a test does,
//  to check that a request raised the right family against the right target. Keeping them here
//  rather than on the type keeps the assertions readable without production code no one calls.
//

import Foundation
@testable import ShuTaPla

extension PendingConfirmation {
    /// The files this confirmation would trash, or `nil` for other kinds.
    var deleteFiles: [PlaylistFile]? {
        guard case .delete(let files) = self else { return nil }
        return files
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

extension FolderPick {
    /// Whether this pick adds a playlist.
    var isAddPlaylist: Bool {
        guard case .addPlaylist = self else { return false }
        return true
    }

    /// The ids of the files this pick would move, or `nil` for other kinds.
    var moveFileIDs: [UUID]? {
        guard case .move(let ids) = self else { return nil }
        return ids
    }
}
