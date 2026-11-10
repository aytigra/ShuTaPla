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
    /// Trash the given files: a Manager selection, or a file in a player overlay.
    case delete([PlaylistFile])
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
    /// The files the confirmation acts on; empty for one without files.
    var files: [PlaylistFile] {
        switch self {
        case .delete(let files), .audioStrip(let files): files
        case .tagRemoval, .playlistDelete, .savedSearchDelete: []
        }
    }

    /// This confirmation with any files a re-scan removed dropped from its payload, or `nil` if
    /// that leaves nothing to confirm — so confirming can't act on (and dereference) a destroyed
    /// model. Non-file confirmations pass through unchanged. Reads `id` of the removed rows, so it
    /// runs where `forgetRemovedFiles` runs.
    func pruning(removedFileIDs removed: Set<UUID>) -> PendingConfirmation? {
        switch self {
        case .delete(let files):
            let kept = files.excluding(removed)
            return kept.isEmpty ? nil : .delete(kept)
        case .audioStrip(let files):
            let kept = files.excluding(removed)
            return kept.isEmpty ? nil : .audioStrip(kept)
        case .tagRemoval, .playlistDelete, .savedSearchDelete:
            return self
        }
    }
}

extension PendingConfirmation {
    /// The question the confirmation asks, naming its target — one file by name, several by count.
    var title: String {
        switch self {
        case .delete(let files):
            files.count.pluralized(
                one: "Move “\(files[0].fileName)” to the Trash?",
                many: "Move \(files.count) files to the Trash?"
            )
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
        case .delete(let files):
            files.count.pluralized(
                one: "The file is moved to the Trash and removed from this playlist.",
                many: "The files are moved to the Trash and removed from this playlist."
            )
        case .audioStrip:
            "The original is moved to the Trash."
        case .tagRemoval:
            "This renames the files on disk and can't be undone."
        case .playlistDelete:
            "This removes the playlist from \(AppConstants.appName). The files on disk are not touched."
        case .savedSearchDelete:
            "Its tag lists go with it, leaving the playlist unfiltered if it is the one applied."
        }
    }

    /// The label on the destructive button — the act, not "OK".
    var confirmLabel: String {
        switch self {
        case .delete: "Move to Trash"
        case .audioStrip: "Remove Audio"
        case .tagRemoval: "Remove Tag"
        case .playlistDelete, .savedSearchDelete: "Delete"
        }
    }
}

/// An operation failed or was refused, in the words of the site that knows why. One channel for
/// every such report — a destructive confirmation's work, a tag edit, a failed
/// save — so a single host can present them all without losing each site's wording, and the
/// `HotkeyRouter` has one flag to register rather than one per surface.
struct ErrorNotice: Equatable {
    let title: String
    let message: String

    /// Every report title. An operation's request-time refusal and its own failure report share one.
    enum Title {
        static let saveFailed = "Couldn't save your changes"
        static let addPlaylist = "Couldn't add playlist"
        static let folderNotFound = "Folder not found"
        static let alreadySaved = "Already saved"
        static let trash = "Couldn't move to Trash"
        static let audioStrip = "Couldn't remove audio"
        static let move = "Couldn't move"
        static let rename = "Couldn't rename"
        static let tagChange = "Tag change failed"
        static let tagRemoval = "Couldn't remove tag"
    }

    /// A failed save. Each caller states whether it rolls the context back.
    static func saveFailed(_ detail: String) -> ErrorNotice {
        ErrorNotice(title: Title.saveFailed, message: detail)
    }

    /// Adding a playlist failed, or its folder has no media.
    static func addPlaylistFailed(_ detail: String) -> ErrorNotice {
        ErrorNotice(title: Title.addPlaylist, message: detail)
    }

    /// A playlist whose folder bookmark doesn't resolve. The files are the source of truth, so the
    /// user adds the folder again as a new playlist.
    static func folderNotFound(_ playlistName: String) -> ErrorNotice {
        ErrorNotice(
            title: Title.folderNotFound,
            message: "“\(playlistName)”'s folder can't be found. If it's on a disk that isn't connected, connect the disk and try again. If the folder was deleted, delete the playlist and add the folder again."
        )
    }
}
