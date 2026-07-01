//
//  ModelContext+Playlists.swift
//  ShuTaPla
//
//  ModelContext+Playlists.swift
//  ShuTaPla
//
//  One place that yields a sidebar section's playlists, so the spots that need a
//  single media type's playlists (next sort order, compaction) share it rather
//  than each fetching and filtering by hand.
//

import Foundation
import SwiftData

extension ModelContext {
    /// The playlists of `mediaType`, ordered by their section `sortOrder`. The fetch
    /// sorts; the media type is filtered in memory because SwiftData can't translate a
    /// predicate over the stored enum property.
    func playlists(ofType mediaType: MediaType) -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortOrder)])
        let all = (try? fetch(descriptor)) ?? []
        return all.filter { $0.mediaType == mediaType }
    }
}
