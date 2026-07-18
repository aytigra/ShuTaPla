//
//  PagedList.swift
//  ShuTaPla
//
//  A fixed-row-height windowed list that stays inert while scrolling: a `ScrollView` over a
//  `LazyVStack` of fixed-height *pages*, each a chunk of rows. It holds no scroll-derived `@State`
//  — the `LazyVStack` windows the pages natively and `ScrollPosition` is set only imperatively for
//  the O(1) open-jump — so `body` never re-renders mid-scroll. It sizes its content from the row
//  count alone (never building a row to measure) and opens on `initialTarget` with no travel.
//  `GalleryPagedList` layers the grid on top of it, mapping items to grid rows.
//
//  `FixedChunks` is the pure index chunking (rows into pages here, items into grid rows for the
//  gallery) and `PagedListGeometry` the pixel geometry — both `nonisolated` and unit-tested.
//

import SwiftUI

/// Partitions a contiguous `0..<total` index space into fixed-size chunks — the shared basis for
/// packing rows into pages (here) and items into grid rows (`GalleryPaging`). Pure integer math,
/// `nonisolated` so it is tested on its own.
nonisolated struct FixedChunks {
    /// Elements per chunk; a non-positive size yields empty results so callers never divide by it.
    let size: Int

    /// Chunks needed for `total` elements, rounding a short final chunk up.
    func count(_ total: Int) -> Int {
        guard size > 0 else { return 0 }
        return (Swift.max(0, total) + size - 1) / size
    }

    /// The half-open range of indices in `chunk`, clamped to `total` so a short final chunk spans
    /// only its real elements (and a stale chunk past the end is empty).
    func range(_ chunk: Int, of total: Int) -> Range<Int> {
        let start = Swift.max(0, chunk) * size
        let end = Swift.min(start + size, Swift.max(0, total))
        return start..<Swift.max(start, end)
    }

    /// The chunk holding `index`.
    func chunk(of index: Int) -> Int {
        guard size > 0 else { return 0 }
        return index / size
    }
}

/// The fixed-height pixel geometry behind `PagedList`: from a row count it yields the total content
/// height, a row's y, and the clamped offsets that jump a target row to the top or reveal it with a
/// minimal scroll. Pure and `nonisolated` so it is tested on its own.
nonisolated struct PagedListGeometry {
    /// Every row's fixed height in points; the whole scheme relies on rows being this tall.
    let rowHeight: CGFloat

    /// Total height of `count` rows — the scroll content size, derived without building any row.
    func contentHeight(count: Int) -> CGFloat { CGFloat(max(0, count)) * rowHeight }

    /// The y position of row `index`'s top edge.
    func offsetY(of index: Int) -> CGFloat { CGFloat(index) * rowHeight }

    /// The scroll offset that brings row `index` to the top of a viewport `height` tall, clamped so
    /// it never scrolls past either content edge (a target near the end stops at the bottom).
    func targetOffset(index: Int, count: Int, height: CGFloat) -> CGFloat {
        let maxOffset = max(0, contentHeight(count: count) - height)
        return min(max(0, offsetY(of: index)), maxOffset)
    }

    /// The minimal scroll offset that brings row `index` fully into a viewport `height` tall
    /// currently scrolled to `currentOffset`: unchanged when the row is already fully visible,
    /// otherwise just enough to bring it to the nearest edge — its top to the viewport top when
    /// above, its bottom to the viewport bottom when below. This is the keyboard-move reveal, so a
    /// selection walks through the viewport untouched and only scrolls once it crosses an edge.
    func revealOffset(index: Int, currentOffset: CGFloat, height: CGFloat, count: Int) -> CGFloat {
        let maxOffset = max(0, contentHeight(count: count) - height)
        let top = offsetY(of: index)
        let bottom = top + rowHeight
        let target: CGFloat
        if top < currentOffset {
            target = top                    // above the viewport: bring its top to the top edge
        } else if bottom > currentOffset + height {
            target = bottom - height        // below the viewport: bring its bottom to the bottom edge
        } else {
            target = currentOffset          // already fully visible: don't move
        }
        return min(max(0, target), maxOffset)
    }
}

/// How a `PagedList` scroll lands: a `.jump` is an instant, top-aligned move (a switch / re-click /
/// filter reflow / launch — the target opens at the top of the viewport); a `.track` is an animated,
/// minimal nearest-edge reveal (a keyboard-move, so the selection walks the viewport and only scrolls
/// once its row crosses an edge).
enum ScrollReveal: Equatable {
    case jump
    case track
}

/// A programmatic scroll a `PagedList` caller issues to reveal a row. `token` lets the same `index`
/// re-scroll — re-clicking the active playlist recenters on a row already positioned — and `mode`
/// picks the landing (top-aligned jump vs. nearest-edge track).
struct ScrollCommand: Equatable {
    let index: Int
    let mode: ScrollReveal
    /// Any value whose change re-applies the command even when `index`/`mode` repeat.
    let token: AnyHashable
}

/// A fixed-row-height windowed list: it sizes its content from `count` rows alone, windows whole
/// pages through the `LazyVStack`, and positions by content offset. `initialTarget` opens the list
/// on a row with no travel (revealed only once positioned); `command` drives later programmatic
/// scrolls. The caller resolves each row lazily in `row` and must tolerate an index momentarily out
/// of its current range (return an empty view) while the sequence changes.
struct PagedList<Row: View>: View {
    let count: Int
    let rowHeight: CGFloat
    /// Row to open at on first appearance (top-aligned, instant), or nil to open at the top.
    let initialTarget: Int?
    /// A later scroll to apply when it changes; nil issues nothing. `index` is a row index.
    let command: ScrollCommand?
    @ViewBuilder let row: (Int) -> Row

    /// Rows per page — the `LazyVStack` windowing granularity. Large enough that a page spans most of
    /// a screenful (so few pages are resident) yet small enough to build cheaply.
    private static var rowsPerPage: Int { 10 }
    private var pages: FixedChunks { FixedChunks(size: Self.rowsPerPage) }
    /// The pixel geometry — content height, the open-jump, and the keyboard reveal — at row
    /// granularity.
    private var window: PagedListGeometry { PagedListGeometry(rowHeight: rowHeight) }
    private var totalPages: Int { pages.count(count) }

    /// The live scroll offset, held in a reference box so the per-frame writes that track a drag
    /// never invalidate `body` — the container stays inert on scroll. Read only when an animated
    /// reveal needs the current position.
    private final class ScrollOffset { var y: CGFloat = 0 }

    @State private var scrollPosition = ScrollPosition()
    @State private var offset = ScrollOffset()
    // Hidden until the first positioning pass runs, so the top never flashes before the list opens
    // on its target — and every page renders empty until then, so the open-jump lands against the
    // honest content height without any page above the target building a row.
    @State private var isPositioned = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<totalPages, id: \.self) { page in
                        PagedListPage(
                            rowIndices: pages.range(page, of: count),
                            rowHeight: rowHeight,
                            resident: isPositioned,
                            row: row
                        )
                    }
                }
            }
            .scrollPosition($scrollPosition)
            // Track the raw offset off to the side (a reference write, not `@State`) so an animated
            // reveal can measure from where the list sits without re-rendering per frame.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                offset.y = y
            }
            .opacity(isPositioned ? 1 : 0)
            .onAppear { openInitial(height: height) }
            .onChange(of: command) { _, cmd in apply(cmd, height: height) }
        }
    }

    /// Positions on `initialTarget`'s row (or the top) before revealing, so the open shows no travel.
    private func openInitial(height: CGFloat) {
        if let initialTarget {
            let y = window.targetOffset(index: initialTarget, count: count, height: height)
            scrollPosition.scrollTo(y: y)
            offset.y = y
        }
        // Reveal a runloop later, once the scroll offset has taken and the pages become resident.
        DispatchQueue.main.async { isPositioned = true }
    }

    /// Applies a later scroll: an animated minimal *reveal* for a keyboard move — a nearest-edge
    /// scroll from where the list sits, so the selection walks the viewport untouched until its row
    /// crosses an edge — and an instant top-aligned jump otherwise (switch / re-click).
    private func apply(_ command: ScrollCommand?, height: CGFloat) {
        guard let command else { return }
        switch command.mode {
        case .track:
            let y = window.revealOffset(index: command.index, currentOffset: offset.y, height: height, count: count)
            withAnimation { scrollPosition.scrollTo(y: y) }
        case .jump:
            let y = window.targetOffset(index: command.index, count: count, height: height)
            scrollPosition.scrollTo(y: y)
            offset.y = y
        }
    }
}

/// One page — the rows it was handed, built as a unit. In the outer `LazyVStack` only near-viewport
/// pages are instantiated; a non-resident page contributes just its fixed height (an empty spacer)
/// so the content stays the right size while its rows stay unbuilt. Each row is framed to `rowHeight`
/// top-aligned, so any inter-row gap baked into `rowHeight` falls below the row.
private struct PagedListPage<Row: View>: View {
    /// This page's row indices, sliced by the container.
    let rowIndices: Range<Int>
    let rowHeight: CGFloat
    /// False until the container has positioned on its target; a non-resident page builds no rows
    /// (an empty `Color.clear` at the page's height), so the open-jump lands against the honest
    /// content height without any page above the target building a row.
    let resident: Bool
    @ViewBuilder let row: (Int) -> Row

    private var pageHeight: CGFloat { CGFloat(rowIndices.count) * rowHeight }

    var body: some View {
        Group {
            if resident { content } else { Color.clear }
        }
        .frame(height: pageHeight, alignment: .top)
    }

    private var content: some View {
        LazyVStack(spacing: 0) {
            ForEach(rowIndices, id: \.self) { index in
                row(index)
                    .frame(height: rowHeight, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
