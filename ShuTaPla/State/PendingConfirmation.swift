//
//  PendingConfirmation.swift
//  ShuTaPla
//
//  The one modal confirmation currently awaiting the user, if any. Modeling the whole
//  confirmation surface as a single optional enum — its case naming the family and carrying
//  that family's payload — makes "two confirmations pending at once" unrepresentable, where a
//  bag of parallel per-family optionals could not.
//
//  Its wording lives here too, as pure properties over the case: one alert host reads them, so a
//  family cannot be worded two ways by two presenters, and the phrasing is unit-testable without
//  a view.
//

import Foundation

/// Which destructive confirmation, if any, is pending — and its target. Presented by the single
/// `RootView` alert host, consulted by `HotkeyRouter` while it owns the keyboard. At most one can
/// be pending, enforced by the type.
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
        guard case .savedSearchDelete(let search) = self,
              searches.contains(where: { $0 === search }) else { return self }
        return nil
    }
}

extension PendingConfirmation {
    /// The question the confirmation asks, naming its target — one file by name, several by count.
    var title: String {
        switch self {
        case .managerDelete(let files):
            files.count.pluralized(
                one: "Move “\(files[0].fileName)” to the Trash?",
                many: "Move \(files.count) files to the Trash?"
            )
        case .playerDelete(let file), .audioDelete(let file):
            "Move “\(file.fileName)” to the Trash?"
        case .audioStrip(let files):
            files.count.pluralized(
                one: "Remove the audio from “\(files[0].fileName)”?",
                many: "Remove the audio from \(files.count) files?"
            )
        case .tagRemoval(let tag):
            "Remove “\(tag)” from every file in this playlist?"
        case .playlistDelete(let playlist):
            "Delete the playlist “\(playlist.name)”?"
        case .savedSearchDelete(let search):
            "Delete the saved search “\(search.name)”?"
        }
    }

    /// What confirming does beyond the obvious — the consequence the title doesn't carry.
    var message: String {
        switch self {
        case .managerDelete(let files):
            files.count.pluralized(
                one: "The file is moved to the Trash and removed from this playlist.",
                many: "The files are moved to the Trash and removed from this playlist."
            )
        case .playerDelete, .audioDelete:
            "The file is moved to the Trash and removed from this playlist."
        case .audioStrip:
            "The original is moved to the Trash."
        case .tagRemoval:
            "This renames the files on disk and can't be undone."
        case .playlistDelete:
            "This removes the playlist from Shutapla. The files on disk are not touched."
        case .savedSearchDelete:
            "Its tag lists go with it, leaving the playlist unfiltered if it is the one applied."
        }
    }

    /// The label on the destructive button — the act, not "OK".
    var confirmLabel: String {
        switch self {
        case .managerDelete, .playerDelete, .audioDelete: "Move to Trash"
        case .audioStrip: "Remove Audio"
        case .tagRemoval: "Remove Tag"
        case .playlistDelete, .savedSearchDelete: "Delete"
        }
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
