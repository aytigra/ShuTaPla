//
//  GalleryPagedList.swift
//  ShuTaPla
//
//  The gallery's windowed container: a `ScrollView` over a `LazyVStack` of fixed-height *pages*,
//  each a chunk of grid rows. Unlike `VirtualList`, it holds no scroll-derived `@State` — the
//  `LazyVStack` windows the pages natively and `ScrollPosition` is set only imperatively for the
//  O(1) open-jump — so the container never re-renders while scrolling. That inertness is the whole
//  reason the gallery uses this rather than `VirtualList`, whose eager whole-band rebuild on every
//  scroll boundary is too costly at N cells per row.
//
//  `GalleryPaging` is the pure page/row/item chunking; the pixel geometry (content height, the
//  open-jump and reveal offsets) reuses `VirtualWindow` at grid-row granularity.
//

import SwiftUI

/// The page/row/item chunking behind `GalleryPagedList`: it maps a flat id sequence into fixed-size
/// pages of grid rows and back, so the container can window whole pages and the open-jump can find
/// the grid row of the current file. Pure integer math, `nonisolated` so it is tested on its own.
nonisolated struct GalleryPaging {
    /// Grid columns per row (the caller's packing guarantees ≥ 1 for any positive width).
    let columns: Int
    /// Grid rows per page — the windowing granularity.
    let rowsPerPage: Int

    /// Grid rows needed for `itemCount` items, rounding a short final row up. Zero for a degenerate
    /// column count so callers never divide by it.
    func totalRows(itemCount: Int) -> Int {
        guard columns > 0 else { return 0 }
        return (Swift.max(0, itemCount) + columns - 1) / columns
    }

    /// Pages needed for `itemCount` items, rounding a short final page up.
    func totalPages(itemCount: Int) -> Int {
        guard rowsPerPage > 0 else { return 0 }
        return (totalRows(itemCount: itemCount) + rowsPerPage - 1) / rowsPerPage
    }

    /// The half-open range of grid rows in `page`, clamped to the existing rows — empty for a page
    /// past the end (tolerating a stale page index while the sequence shrinks under a live window).
    func rows(inPage page: Int, itemCount: Int) -> Range<Int> {
        let start = page * rowsPerPage
        let end = Swift.min(start + rowsPerPage, totalRows(itemCount: itemCount))
        return start..<Swift.max(start, end)
    }

    /// The half-open range of item indices in grid `row`, clamped to `itemCount` so a short final
    /// row packs only its real cells.
    func items(inRow row: Int, itemCount: Int) -> Range<Int> {
        let start = Swift.max(0, row) * columns
        let end = Swift.min(start + columns, Swift.max(0, itemCount))
        return start..<Swift.max(start, end)
    }

    /// The grid row holding item `index` — converts an item-index scroll target to the row the
    /// pixel geometry positions on.
    func row(ofItem index: Int) -> Int {
        guard columns > 0 else { return 0 }
        return index / columns
    }
}

/// A windowed gallery: a `ScrollView` over a `LazyVStack` of fixed-height pages, each a chunk of
/// grid rows of cells. It owns the whole `ids` sequence and the chunking — slicing each page's rows
/// itself and handing a page only the ids it renders — sizes its content from the id count alone,
/// opens on `initialTarget`'s row with no travel (revealed only once positioned), and drives later
/// scrolls from `command`, mirroring `VirtualList`'s interface so the caller routes both surfaces
/// the same way. `cell` resolves one id to its view.
struct GalleryPagedList<ID: Hashable, Cell: View>: View {
    let ids: [ID]
    let columns: Int
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let spacing: CGFloat
    /// Item to open at on first appearance (its row, top-aligned, instant), or nil to open at the top.
    let initialTarget: Int?
    /// A later scroll to apply when it changes; nil issues nothing. `index` is an *item* index.
    let command: VirtualScrollCommand?
    @ViewBuilder let cell: (ID) -> Cell

    /// Grid rows per page — the `LazyVStack` windowing granularity. Large enough that a page spans
    /// most of a screenful (so few pages are resident) yet small enough to build cheaply.
    private static var rowsPerPage: Int { 10 }
    private var paging: GalleryPaging { GalleryPaging(columns: columns, rowsPerPage: Self.rowsPerPage) }
    /// A grid row's pixel height: the tile plus the inter-row gap, uniform across pages so the
    /// content height and the open-jump are exact.
    private var rowPixelHeight: CGFloat { tileHeight + spacing }
    /// The pixel geometry reused at grid-row granularity — content height, the open-jump, and the
    /// keyboard reveal. Overscan is irrelevant here (the `LazyVStack` windows pages natively).
    private var window: VirtualWindow { VirtualWindow(rowHeight: rowPixelHeight, overscan: 0) }
    private var totalRows: Int { paging.totalRows(itemCount: ids.count) }
    private var totalPages: Int { paging.totalPages(itemCount: ids.count) }

    /// The live scroll offset, held in a reference box so the per-frame writes that track a drag
    /// never invalidate `body` — the container stays inert on scroll. Read only when an animated
    /// reveal needs the current position.
    private final class ScrollOffset { var y: CGFloat = 0 }

    @State private var scrollPosition = ScrollPosition()
    @State private var offset = ScrollOffset()
    // Hidden until the first positioning pass runs, so the top never flashes before the gallery
    // opens on its target — and every page renders empty until then, so the open-jump lands against
    // the honest content height without any page above the target building a cell.
    @State private var isPositioned = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<totalPages, id: \.self) { page in
                        GalleryPage(
                            rows: rows(inPage: page),
                            tileWidth: tileWidth, tileHeight: tileHeight, spacing: spacing,
                            rowPixelHeight: rowPixelHeight, resident: isPositioned, cell: cell
                        )
                    }
                }
            }
            .scrollPosition($scrollPosition)
            // Track the raw offset off to the side (a reference write, not `@State`) so an animated
            // reveal can measure from where the gallery sits without re-rendering per frame.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                offset.y = y
            }
            .opacity(isPositioned ? 1 : 0)
            .onAppear { openInitial(height: height) }
            .onChange(of: command) { _, cmd in apply(cmd, height: height) }
        }
    }

    /// The page's grid rows, each already sliced to its own ids — the container owns the chunking so
    /// a page holds no sequence and computes nothing, it just renders the ids it is handed.
    private func rows(inPage page: Int) -> [ArraySlice<ID>] {
        paging.rows(inPage: page, itemCount: ids.count).map { row in
            ids[paging.items(inRow: row, itemCount: ids.count)]
        }
    }

    /// Positions on `initialTarget`'s row (or the top) before revealing, so the open shows no travel.
    private func openInitial(height: CGFloat) {
        if let initialTarget {
            let y = window.targetOffset(index: paging.row(ofItem: initialTarget), count: totalRows, height: height)
            scrollPosition.scrollTo(y: y)
            offset.y = y
        }
        // Reveal a runloop later, once the scroll offset has taken and the pages become resident.
        DispatchQueue.main.async { isPositioned = true }
    }

    /// Applies a later scroll: an animated minimal *reveal* for a keyboard move — a nearest-edge
    /// scroll from where the gallery sits, so the selection walks the viewport untouched until its
    /// row crosses an edge — and an instant top-aligned jump otherwise (switch / re-click).
    private func apply(_ command: VirtualScrollCommand?, height: CGFloat) {
        guard let command else { return }
        let row = paging.row(ofItem: command.index)
        if command.animated {
            let y = window.revealOffset(index: row, currentOffset: offset.y, height: height, count: totalRows)
            withAnimation { scrollPosition.scrollTo(y: y) }
        } else {
            let y = window.targetOffset(index: row, count: totalRows, height: height)
            scrollPosition.scrollTo(y: y)
            offset.y = y
        }
    }
}

/// One page — the grid rows it was handed, built as a unit. In the outer `LazyVStack` only
/// near-viewport pages are instantiated; a non-resident page contributes just its fixed height (an
/// empty spacer) so the content stays the right size while its cells stay unbuilt.
private struct GalleryPage<ID: Hashable, Cell: View>: View {
    /// This page's grid rows, each already sliced to its ids by the container.
    let rows: [ArraySlice<ID>]
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let spacing: CGFloat
    let rowPixelHeight: CGFloat
    /// False until the container has positioned on the current file; a non-resident page builds no
    /// cells (an empty `Color.clear` at the page's height), so the open-jump lands against the honest
    /// content height without any page above the target building a cell.
    let resident: Bool
    @ViewBuilder let cell: (ID) -> Cell

    private var pageHeight: CGFloat { CGFloat(rows.count) * rowPixelHeight }

    var body: some View {
        Group {
            if resident { content } else { Color.clear }
        }
        .frame(height: pageHeight, alignment: .top)
    }

    private var content: some View {
        LazyVStack(spacing: spacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(rows[row], id: \.self) { id in
                        cell(id).frame(width: tileWidth, height: tileHeight, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, spacing)
    }
}
