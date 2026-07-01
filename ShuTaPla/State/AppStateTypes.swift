//
//  AppStateTypes.swift
//  ShuTaPla
//
//  The small value types the `AppState` orchestration passes around: the window's
//  current mode, a grid navigation step, and the playlist-creation payloads.
//

import Foundation

/// What the single window is currently showing.
enum AppMode {
    case welcome   // no playlists yet
    case manager   // library / file management
    case player    // fullscreen playback
}

/// A directional step for keyboard navigation of the Manager file grid.
enum MoveDirection {
    case up, down, left, right
}

/// A scanned folder awaiting a media-type decision because no type dominated it
/// (a Mixed folder). The view presents the choice and calls back with the type.
struct PendingPlaylist {
    let name: String
    let bookmark: Data
    let folderPath: String
    let scan: ScanResult
}

extension PendingPlaylist {
    /// Media types present in the Mixed folder, ordered by frequency (most first) —
    /// the choices the type dialog offers.
    var typeChoices: [MediaType] {
        scan.counts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    /// A choice button's label: the type name with its file count, e.g. "Video (12)".
    func choiceLabel(for type: MediaType) -> String {
        "\(type.displayName) (\(scan.counts[type] ?? 0))"
    }
}

/// A folder being scanned into a new playlist, shown optimistically in the
/// sidebar (with a spinner) until the finished playlist replaces it.
struct ImportingPlaylist: Identifiable {
    let id = UUID()
    let name: String
}

/// Outcome of picking a folder and scanning it.
enum AddPlaylistOutcome {
    /// A single dominant type was detected; the playlist was created.
    case created(Playlist)
    /// The folder is Mixed; the caller must prompt for a media type and then
    /// call `confirmPlaylist(_:mediaType:)`.
    case needsTypeChoice(PendingPlaylist)
    /// No recognized media files were found.
    case empty
    /// Bookmark creation or scanning failed.
    case failed(String)
}
