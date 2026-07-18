//
//  GalleryGrid.swift
//  ShuTaPla
//
//  The Manager gallery's adaptive column packing: from an available width it computes the column
//  count and tile width — replicating `LazyVGrid`'s `.adaptive(minimum:maximum:)` so a
//  `GalleryPagedList` can size its rows without measuring rendered cells — and derives the fixed row
//  height that windowing needs. Pure geometry, `nonisolated` and unit-tested.
//

import CoreGraphics

nonisolated enum GalleryGrid {
    /// The `LazyVGrid` column metrics.
    /// `galleryMinItemWidth` is the default adaptive minimum when a playlist hasn't chosen its own;
    /// `galleryMaxRatio` sets the adaptive maximum as a multiple of the minimum, so a wider minimum
    /// still leaves headroom for the grid to repack before adding a column.
    static let galleryMinItemWidth: CGFloat = 200
    static let galleryMaxRatio: CGFloat = 1.8
    static let gallerySpacing: CGFloat = 4

    /// A gallery tile's inner padding (matched by `GalleryCell`) and the fixed chrome added below
    /// its 4:3 thumbnail — the caption gap plus the two-line caption's reserved height. The chrome
    /// is deliberately generous so a tile framed to `rowHeight(tileWidth:)` never clips; any slack
    /// falls harmlessly below the caption.
    static let galleryTilePadding: CGFloat = 3
    static let galleryCaptionChrome: CGFloat = 42

    /// The adaptive grid's (minimum, maximum) tile widths for a playlist's chosen minimum.
    /// A `nil` choice (never set) falls back to `galleryMinItemWidth`; the maximum is always
    /// `galleryMaxRatio ×` the minimum.
    static func gridMetrics(min chosen: Double?) -> (min: CGFloat, max: CGFloat) {
        let minimum = chosen.map { CGFloat($0) } ?? galleryMinItemWidth
        return (minimum, minimum * galleryMaxRatio)
    }

    /// The column count and tile width for an available `width`, replicating `LazyVGrid`'s
    /// `.adaptive(minimum:maximum:)` packing so a `PagedList` gallery can size its rows without
    /// measuring rendered cells: fit as many `min`-wide columns as the width allows (at least one),
    /// then widen each to share the width evenly, capped at `max`.
    static func gridLayout(width: CGFloat, min: CGFloat, max: CGFloat, spacing: CGFloat) -> (columns: Int, tileWidth: CGFloat) {
        guard width > 0, min > 0 else { return (1, Swift.max(0, width)) }
        let columns = Swift.max(1, Int((width + spacing) / (min + spacing)))
        let tileWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return (columns, Swift.min(tileWidth, max))
    }

    /// A gallery row's fixed height for a given tile width: the 4:3 thumbnail (inset by the tile
    /// padding on each side) plus the caption/padding chrome. The whole windowing scheme relies on
    /// every row being exactly this tall.
    static func rowHeight(tileWidth: CGFloat) -> CGFloat {
        (tileWidth - 2 * galleryTilePadding) * 3 / 4 + galleryCaptionChrome
    }
}
