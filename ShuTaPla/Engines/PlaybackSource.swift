//
//  PlaybackSource.swift
//  ShuTaPla
//
//  The seam between a playback engine and whatever decides *what* it plays.
//  An engine knows how to play the current file and, on a natural end or a
//  next/previous command, asks its source for the adjacent file and a URL to
//  load it from. The source owns the playback order (already filtered) and the
//  bookmark→URL resolution — concerns that belong to the `PlaybackCoordinator`
//  (Task 11), which conforms to this protocol. Tests supply a mock.
//

import Foundation

@MainActor
protocol PlaybackSource: AnyObject {
    /// The file to play after `current` in playback order, wrapping past the last
    /// back to the first. `nil` when there is nothing playable. Passing `nil` for
    /// `current` returns the first file. Order follows the active filter, so
    /// non-matching files are skipped.
    func fileAfter(_ current: PlaylistFile?) -> PlaylistFile?

    /// The file to play before `current`, wrapping from the first back to the last.
    /// `nil` when there is nothing playable.
    func fileBefore(_ current: PlaylistFile?) -> PlaylistFile?

    /// A URL the engine can load `file` from, with folder access already arranged,
    /// or `nil` when it can't be resolved (e.g. a stale bookmark or a missing file).
    func url(for file: PlaylistFile) -> URL?
}
