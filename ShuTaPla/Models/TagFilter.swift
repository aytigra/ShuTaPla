//
//  TagFilter.swift
//  ShuTaPla
//
//  A playlist's tag filter: four independent tag lists, AND-joined, one per combination of polarity
//  and quantifier. There is no match mode — which rule applies is *which list the tag was typed
//  into*. A file matches when all four hold, and an empty list is vacuously true.
//
//  Store rows rather than a value embedded on `Playlist`: `captureResumePosition` fires from
//  `setCurrentFile` on every file switch, and against a row that is a one-column write instead of
//  re-encoding a whole JSON blob.
//

import Foundation
import SwiftData

/// A key over `TagFilter`'s four lists, not stored state. Everything that acts on all four — the
/// rewrite/drop passes, the AppState edits, the strip's grid — iterates `allCases` and subscripts,
/// so no site enumerates the lists by hand.
nonisolated enum TagFilterField: String, Sendable, CaseIterable {
    case mustHaveAll
    case mustHaveAny
    case mustNotHaveAll
    case mustNotHaveAny

    /// Field label above the token field.
    var label: String {
        switch self {
        case .mustHaveAll: return "Must have all"
        case .mustHaveAny: return "Must have any"
        case .mustNotHaveAll: return "Must not have all"
        case .mustNotHaveAny: return "Must not have any"
        }
    }

    /// The lead-in of a saved search's summary line, where four full labels would crowd out the tags
    /// they introduce. A clipped `label` rather than a rewording, so a segment still reads as the
    /// field it came from.
    var shortLabel: String {
        switch self {
        case .mustHaveAll: return "Have all"
        case .mustHaveAny: return "Have any"
        case .mustNotHaveAll: return "Not all"
        case .mustNotHaveAny: return "Not any"
        }
    }

    /// Whether the list keeps files out rather than letting them in — the one axis worth showing in
    /// a summary, since two fields there differ by a single word.
    var excludes: Bool {
        switch self {
        case .mustHaveAll, .mustHaveAny: return false
        case .mustNotHaveAll, .mustNotHaveAny: return true
        }
    }
}

@Model
final class TagFilter {
    // User-entered order, kept for display.
    var mustHaveAll: [String] = []
    var mustHaveAny: [String] = []
    var mustNotHaveAll: [String] = []
    var mustNotHaveAny: [String] = []

    /// The playlist applying this filter right now — the inverse of `Playlist.currentFilter`, so it
    /// is nil on a saved search's filter while some other filter is live. Together with
    /// `savedSearch` it is what makes a filter reachable: a row with neither set is unreachable and
    /// must never exist.
    var playlist: Playlist?

    /// The name and resume position saved over these lists; nil ⇒ ad-hoc filter. Cascades both ways
    /// with `SavedSearch.filter`, because neither row means anything without the other.
    @Relationship(deleteRule: .cascade, inverse: \SavedSearch.filter)
    var savedSearch: SavedSearch?

    init() {}

    subscript(field: TagFilterField) -> [String] {
        get {
            switch field {
            case .mustHaveAll: return mustHaveAll
            case .mustHaveAny: return mustHaveAny
            case .mustNotHaveAll: return mustNotHaveAll
            case .mustNotHaveAny: return mustNotHaveAny
            }
        }
        set {
            switch field {
            case .mustHaveAll: mustHaveAll = newValue
            case .mustHaveAny: mustHaveAny = newValue
            case .mustNotHaveAll: mustNotHaveAll = newValue
            case .mustNotHaveAny: mustNotHaveAny = newValue
            }
        }
    }

    /// Every list empty — the filter matches everything, so the row has nothing left to say and is
    /// deleted rather than kept.
    var isEmpty: Bool {
        TagFilterField.allCases.allSatisfy { self[$0].isEmpty }
    }

    /// The filled fields in `allCases` order with their lists — the one traversal the predicate
    /// builder and the saved-search summary line share.
    var filledFields: [(field: TagFilterField, tags: [String])] {
        TagFilterField.allCases.compactMap { field in
            let tags = self[field]
            return tags.isEmpty ? nil : (field, tags)
        }
    }

    /// Each field's lowercased tag set — two filters are the same combination when these are equal,
    /// which is the comparison a duplicate saved search is refused on. Lowercasing is the same
    /// normalization `Tag.normalizedName` and the query layer's thresholds use.
    var normalizedFields: [TagFilterField: Set<String>] {
        TagFilterField.allCases.reduce(into: [:]) { result, field in
            result[field] = Set(self[field].map { $0.lowercased() })
        }
    }

    /// Maps every tag of every list through `transform`, deduping each list — the playlist-wide tag
    /// rename applied to a filter.
    func rewriteTags(_ transform: (String) -> String) {
        for field in TagFilterField.allCases {
            self[field] = TagParser.dedupe(self[field].map(transform))
        }
    }

    /// Drops `tag` from every list after a playlist-wide removal.
    func dropTag(_ tag: String) {
        for field in TagFilterField.allCases {
            self[field] = self[field].filter { !TagParser.sameTag($0, tag) }
        }
    }
}
