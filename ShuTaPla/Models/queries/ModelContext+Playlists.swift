//
//  ModelContext+Playlists.swift
//  ShuTaPla
//
//  ModelContext+Playlists.swift
//  ShuTaPla
//
//  One place that yields playlists in section order, so the spots that need them
//  (the selectors, next sort order, compaction) share it rather than each fetching
//  and filtering by hand.
//

import Foundation
import SwiftData

extension ModelContext {
    /// Every playlist, ordered by its section `sortOrder`. Callers filter by media type in
    /// memory because SwiftData can't translate a predicate over the stored enum property.
    func playlistsInSectionOrder() -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortOrder)])
        return (try? fetch(descriptor)) ?? []
    }

    /// The playlists of `mediaType`, ordered by their section `sortOrder`.
    func playlists(ofType mediaType: MediaType) -> [Playlist] {
        playlistsInSectionOrder().filter { $0.mediaType == mediaType }
    }
}
