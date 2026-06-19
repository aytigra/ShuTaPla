//
//  SourceNavigating.swift
//  ShuTaPla
//
//  The advance/previous step shared by every playback engine. An engine holds a
//  weak `PlaybackSource` (what plays next), tracks its `currentFile` (the anchor),
//  and knows how to `load` a file from a URL; stepping forward or back is the same
//  three lines over that seam regardless of whether the engine is mpv- or image-
//  backed, so it lives once here as a protocol default.
//

import Foundation

@MainActor
protocol SourceNavigating: AnyObject {
    /// Supplies the next/previous file and its URL. Weak; the coordinator owns it.
    var source: PlaybackSource? { get }

    /// The file the engine considers current — the anchor for advance/previous.
    var currentFile: PlaylistFile? { get }

    /// Loads and starts the given file from `url`.
    func load(_ file: PlaylistFile?, at url: URL)
}

extension SourceNavigating {

    /// Loads the next file from `source`, wrapping past the last to the first.
    /// Returns `false` when there is nothing to advance to — including when the
    /// successor is the current file itself (a one-element sequence, or the only
    /// match under the active filter): the current file is held in place rather
    /// than re-loaded and re-decoded, so a natural end-of-file or slideshow tick
    /// doesn't flicker or reset pan/zoom.
    @discardableResult
    func advanceToNext() -> Bool {
        guard let source,
              let next = source.fileAfter(currentFile),
              next !== currentFile,
              let url = source.url(for: next) else { return false }
        load(next, at: url)
        source.engineDidAdvance(to: next)
        return true
    }

    /// Loads the previous file from `source`, wrapping from the first to the last.
    /// Returns `false` when there is nothing to step back to — including when the
    /// predecessor is the current file itself (see `advanceToNext`).
    @discardableResult
    func returnToPrevious() -> Bool {
        guard let source,
              let previous = source.fileBefore(currentFile),
              previous !== currentFile,
              let url = source.url(for: previous) else { return false }
        load(previous, at: url)
        source.engineDidAdvance(to: previous)
        return true
    }
}
