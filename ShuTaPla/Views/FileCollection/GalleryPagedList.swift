//
//  GalleryPagedList.swift
//  ShuTaPla
//
//  The gallery's windowed grid: a thin layer over `PagedList` that turns a flat id sequence into
//  grid rows of cells. `PagedList` owns the vertical windowing (fixed-height pages, the inert
//  scroll, the O(1) open-jump); this wrapper adds only the grid — mapping the item-index
//  `initialTarget`/`command` to their grid row and packing each row's ids into an HStack of tiles.
//
//  `GalleryPaging` is the pure item↔row mapping, backed by `FixedChunks`; the pixel geometry lives
//  in `PagedList`.
//

import SwiftUI

/// The item↔row mapping behind `GalleryPagedList`: how many grid rows a given item count needs, the
/// item indices in a row, and the row holding an item. A thin domain facade over `FixedChunks`
/// (chunk size = columns), `nonisolated` so it is tested on its own.
nonisolated struct GalleryPaging {
    /// Grid columns per row (the caller's packing guarantees ≥ 1 for any positive width).
    let columns: Int

    private var rows: FixedChunks { FixedChunks(size: columns) }

    /// Grid rows needed for `itemCount` items, rounding a short final row up.
    func totalRows(itemCount: Int) -> Int { rows.count(itemCount) }

    /// The half-open range of item indices in grid `row`, clamped to `itemCount` so a short final
    /// row packs only its real cells.
    func items(inRow row: Int, itemCount: Int) -> Range<Int> { rows.range(row, of: itemCount) }

    /// The grid row holding item `index` — converts an item-index scroll target to its row.
    func row(ofItem index: Int) -> Int { rows.chunk(of: index) }
}

/// A windowed gallery grid: it maps `ids` into grid rows of `columns` cells and hands them to a
/// `PagedList`, sizing content from the id count alone, opening on `initialTarget`'s row with no
/// travel, and driving later scrolls from `command` (both *item* indices, converted to their grid
/// row). `cell` resolves one id to its view.
struct GalleryPagedList<ID: Hashable, Cell: View>: View {
    let ids: [ID]
    let columns: Int
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let spacing: CGFloat
    /// Item to open at on first appearance (its row, top-aligned, instant), or nil to open at the top.
    let initialTarget: Int?
    /// A later scroll to apply when it changes; nil issues nothing. `index` is an *item* index.
    let command: ScrollCommand?
    @ViewBuilder let cell: (ID) -> Cell

    private var paging: GalleryPaging { GalleryPaging(columns: columns) }
    /// A grid row's pixel height: the tile plus the inter-row gap, baked into the row so `PagedList`
    /// frames each row top-aligned and the gap falls below it.
    private var rowPixelHeight: CGFloat { tileHeight + spacing }

    var body: some View {
        PagedList(
            count: paging.totalRows(itemCount: ids.count),
            rowHeight: rowPixelHeight,
            initialTarget: initialTarget.map { paging.row(ofItem: $0) },
            command: command.map {
                ScrollCommand(index: paging.row(ofItem: $0.index), mode: $0.mode, token: $0.token)
            },
            row: gridRow
        )
    }

    /// One grid row: its ids packed left-to-right, each in a fixed tile, with the inter-cell and edge
    /// spacing. The row's height (tile + inter-row gap) is framed by `PagedList`.
    private func gridRow(_ row: Int) -> some View {
        HStack(spacing: spacing) {
            ForEach(ids[paging.items(inRow: row, itemCount: ids.count)], id: \.self) { id in
                cell(id).frame(width: tileWidth, height: tileHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, spacing)
    }
}
