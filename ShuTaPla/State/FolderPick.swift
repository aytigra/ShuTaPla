//
//  FolderPick.swift
//  ShuTaPla
//
//  What a folder pick is for. One `.fileImporter` (`FolderPickFlow`) presents every pick and
//  branches on the case when it completes.
//

import Foundation

/// What a folder pick is for. Set on `AppState.folderPick` to raise the chooser.
enum FolderPick {
    /// Scan the chosen folder into a new playlist.
    case addPlaylist
    /// Move the files with the given ids into the chosen folder. The chooser is the confirmation.
    /// Ids, not rows: a re-scan can prune a file while the pick is queued or shown, and a read of a
    /// pruned row traps. The completion resolves the ids to the rows still in the store.
    case move([UUID])
}
