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
    /// invalid-tagging); mutually exclusive with itself. Decodes to `nil` from filters
    /// persisted before triage filters were stored.
    var serviceFilter: ServiceFilter?

    init() {}

    init(selectedTags: [String], filterMode: FilterMode, serviceFilter: ServiceFilter? = nil) {
        self.selectedTags = selectedTags
        self.filterMode = filterMode
        self.serviceFilter = serviceFilter
    }

    /// Decodes leniently so an *unrecognized* `serviceFilter` — a triage-filter case removed in a
    /// later version, sitting in an existing store's blob — coerces to `nil` ("no filter") instead
    /// of failing the whole composite decode. Synthesized `decodeIfPresent` throws on a
    /// present-but-unknown raw value; `try?` turns that into `nil`. An absent key already yields
    /// `nil`, and the tag fields keep their defaults exactly as the synthesized decode would.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedTags = try container.decodeIfPresent([String].self, forKey: .selectedTags) ?? []
        filterMode = try container.decodeIfPresent(FilterMode.self, forKey: .filterMode) ?? .and
        serviceFilter = try? container.decodeIfPresent(ServiceFilter.self, forKey: .serviceFilter)
    }

    /// No tags selected — the tag filter matches everything.
    var isEmpty: Bool { selectedTags.isEmpty }

    /// At least one tag selected — the positive reading of `!isEmpty`.
    var isNotEmpty: Bool { !isEmpty }

    /// Adds or removes `tag` from the tag filter, clearing any active triage filter — editing the
    /// tag filter and holding a triage filter are mutually exclusive.
    mutating func toggle(tag: String) {
        serviceFilter = nil
        if let index = selectedTags.firstIndex(where: { TagParser.sameTag($0, tag) }) {
            selectedTags.remove(at: index)
        } else {
            selectedTags.append(tag)
        }
    }

    /// Sets or unsets the triage filter (mutually exclusive with itself). While set it overrides
    /// the tag filter.
    mutating func toggle(service filter: ServiceFilter) {
        serviceFilter = (serviceFilter == filter) ? nil : filter
    }

    /// Clears the tag filter, leaving any triage filter in place.
    mutating func clearTags() {
        selectedTags = []
    }

    /// Replaces the tag filter with a single tag, clearing any active triage filter.
    mutating func setOnly(tag: String) {
        serviceFilter = nil
        selectedTags = [tag]
    }
}
