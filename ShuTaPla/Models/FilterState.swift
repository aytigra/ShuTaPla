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

    init() {}

    init(selectedTags: [String], filterMode: FilterMode) {
        self.selectedTags = selectedTags
        self.filterMode = filterMode
    }

    /// No tags selected — the filter matches everything.
    var isEmpty: Bool { selectedTags.isEmpty }
}
