//
//  FilterStripLayout.swift
//  ShuTaPla
//
//  The filter strip's two pure decisions, kept out of the view so both are unit-tested: which one
//  thing the strip shows, and how many columns its four token fields pack into at a given width.
//

import CoreGraphics

/// What the strip shows, as one total ordering over everything that narrows a playlist — each case
/// showing exactly one thing. A review mode and a triage filter each *hide* the tag filter rather
/// than combining with it, which is what the store does too: `sequencePredicate` prefers the service
/// filter over the tag filter. Hidden is not lost — the triage filter always carries its own way
/// out, and clearing it drops straight back to `.tagFiltered` with the tag lists intact, which is
/// the whole reason the model keeps the two independent.
nonisolated enum FilterStripMode: Equatable {
    /// A Manager review surface (duplicates, skipped) — its banner alone.
    case reviewing
    /// A triage filter — its "Showing …" state and the way out of it, alone.
    case serviceFiltered(ServiceFilter)
    /// A tag filter is set — the filter controls, with the triage counts hidden.
    case tagFiltered
    /// Nothing narrows the playlist — the filter controls and the triage counts.
    case unfiltered

    static func resolve(
        inReviewMode: Bool, serviceFilter: ServiceFilter?, hasTagFilter: Bool
    ) -> FilterStripMode {
        if inReviewMode { return .reviewing }
        if let serviceFilter { return .serviceFiltered(serviceFilter) }
        return hasTagFilter ? .tagFiltered : .unfiltered
    }

    /// Whether `Filter` and `Searches` — and so the expanded panel behind them — are reachable.
    var showsFilterControls: Bool { self == .tagFiltered || self == .unfiltered }

    /// `Clear` shows only when there is a tag filter for it to clear.
    var showsClear: Bool { self == .tagFiltered }

    /// The triage counts show only while nothing else narrows the playlist: under a tag filter they
    /// would offer to replace it, and a set triage filter shows its own state instead of its counts.
    var showsTriageCounts: Bool { self == .unfiltered }
}

/// How the four token fields pack across the strip's width.
nonisolated enum FilterStripLayout {
    /// The narrowest a token field stays usable at — its label, and a chip or two beside the input.
    static let minimumFieldWidth: CGFloat = 220

    /// Four, two, or one column. The count halves rather than stepping by one, so the four fields
    /// always divide evenly and no row is left ragged.
    static func columns(forWidth width: CGFloat) -> Int {
        if width >= 4 * minimumFieldWidth { return 4 }
        return width >= 2 * minimumFieldWidth ? 2 : 1
    }
}
