//
//  FilterState.swift
//  ShuTaPla
//
//  Embedded value type stored on `Playlist` — the persisted tag filter.
//

import Foundation

nonisolated struct FilterState: Codable, Sendable, Equatable {
    var selectedTags: [String] = []
    var filterMode: FilterMode = .and

    /// The active triage filter. While set it overrides the tag filter (untagged /
    /// invalid-tagging / skipped); mutually exclusive with itself. Decodes to `nil`
    /// from filters persisted before triage filters were stored.
    var serviceFilter: ServiceFilter?

    init() {}

    init(selectedTags: [String], filterMode: FilterMode, serviceFilter: ServiceFilter? = nil) {
        self.selectedTags = selectedTags
        self.filterMode = filterMode
        self.serviceFilter = serviceFilter
    }

    /// No tags selected — the tag filter matches everything.
    var isEmpty: Bool { selectedTags.isEmpty }
}
