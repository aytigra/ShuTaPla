//
//  PendingConfirmation.swift
//  ShuTaPla
//
//  The one modal confirmation currently awaiting the user, if any. Modeling the whole
//  confirmation surface as a single optional enum — its case naming the family and carrying
//  that family's payload — makes "two confirmations pending at once" unrepresentable, where a
//  bag of parallel per-family optionals could not.
//

import Foundation

/// Which destructive confirmation, if any, is pending — and its target. Presented by the
/// matching `.alert` / `.confirmationDialog` host, consulted by `HotkeyRouter` while it owns
/// the keyboard. At most one can be pending, enforced by the type.
enum PendingConfirmation {
    /// Trash the given Manager file-list selection.
    case managerDelete([PlaylistFile])
    /// Trash the file playing on the visual channel.
    case playerDelete(PlaylistFile)
    /// Trash the audio channel's current track (from the extended overlay).
    case audioDelete(PlaylistFile)
    /// Remove the audio track from the given videos.
    case audioStrip([PlaylistFile])
    /// Remove the given tag from every file in the managed playlist.
    case tagRemoval(String)
    /// Delete the given playlist and its files.
    case playlistDelete(Playlist)
    /// Delete the given saved search, and with it the filter it names.
    case savedSearchDelete(SavedSearch)
}

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

    /// The tag this confirmation would remove playlist-wide, or `nil` for other kinds.
    var tagRemovalTag: String? {
        guard case .tagRemoval(let tag) = self else { return nil }
        return tag
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

    /// This confirmation with any files a re-scan removed dropped from its payload, or `nil` if
    /// that leaves nothing to confirm — so confirming can't act on (and dereference) a destroyed
    /// model. Non-file confirmations pass through unchanged. Reads only the stored `id`, which a
    /// deleted model still surrenders.
    func pruning(removedFileIDs removed: Set<UUID>) -> PendingConfirmation? {
        switch self {
        case .managerDelete(let files):
            let kept = files.filter { !removed.contains($0.id) }
            return kept.isEmpty ? nil : .managerDelete(kept)
        case .audioStrip(let files):
            let kept = files.filter { !removed.contains($0.id) }
            return kept.isEmpty ? nil : .audioStrip(kept)
        case .playerDelete(let file):
            return removed.contains(file.id) ? nil : self
        case .audioDelete(let file):
            return removed.contains(file.id) ? nil : self
        case .tagRemoval, .playlistDelete, .savedSearchDelete:
            return self
        }
    }

    /// This confirmation unless it names one of `searches`, in which case `nil` — the saved-search
    /// counterpart to the file pruning above, for the other way a target is destroyed under a
    /// confirmation that is already on screen: a playlist-wide tag removal empties a search's filter
    /// and the cascade takes the search. Compares by identity, so nothing is read off the gone rows.
    func pruning(destroyedSearches searches: [SavedSearch]) -> PendingConfirmation? {
        guard let search = savedSearchToDelete,
              searches.contains(where: { $0 === search }) else { return self }
        return nil
    }
}

/// An operation failed or was refused, in the words of the site that knows why. One channel for
/// every such report — a destructive confirmation's work, a tag edit, a save the store already
/// covers — so a single host can present them all without losing each site's wording, and the
/// `HotkeyRouter` has one flag to register rather than one per surface.
struct ErrorNotice {
    let title: String
    let message: String
}
