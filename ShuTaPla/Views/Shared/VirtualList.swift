//
//  VirtualList.swift
//  ShuTaPla
//
//  A fixed-row-height windowed list: it sizes its scroll content from the row count alone
//  (never instantiating a row to measure), renders only the small band of rows around the
//  viewport, and positions by content offset — an O(1) one-way jump, not a per-row walk. The
//  file surfaces use it because neither `LazyVStack` nor `List` gives both a virtualized *jump*
//  and a virtualized *build*: `List` builds every row on a switch, and `LazyVStack.scrollTo`
//  prefix-walks to a far target.
//
//  `VirtualWindow` is the pure windowing math — content size, the visible index band, a row's y,
//  and the clamped jump offset — unit-tested independently of the view.
//

import SwiftUI

/// The fixed-height windowing math behind `VirtualList`: from a scroll offset and viewport
/// height it yields the band of row indices to build, the total content height, a row's y, and
/// the offset that brings a target row to the top. Pure and `nonisolated` so it is tested on its own.
nonisolated struct VirtualWindow {
    /// Every row's fixed height in points; the whole scheme relies on rows being this tall.
    let rowHeight: CGFloat
    /// Extra rows built above and below the viewport so a fast scroll never flashes a blank band.
    let overscan: Int

    /// Total height of `count` rows — the scroll content size, derived without building any row.
    func contentHeight(count: Int) -> CGFloat { CGFloat(max(0, count)) * rowHeight }

    /// The half-open range of row indices to instantiate for a viewport `height` tall scrolled to
    /// `offset`, padded by `overscan` on each side and clamped to `0..<count`. Empty when there is
    /// nothing to show or the geometry is degenerate (non-positive height / row height).
    func visibleRange(offset: CGFloat, height: CGFloat, count: Int) -> Range<Int> {
        guard count > 0, rowHeight > 0, height > 0 else { return 0..<0 }
        let firstVisible = Int((offset / rowHeight).rounded(.down))
        let lastVisible = Int(((offset + height) / rowHeight).rounded(.up))
        let lower = max(0, firstVisible - overscan)
        let upper = min(count, lastVisible + overscan)
        return lower..<max(lower, upper)
    }

    /// The index of the first row touching the viewport at `offset`, clamped to `0..<count` (the
    /// last valid index when scrolled to the very bottom). This is the boundary-crossing signal the
    /// view throttles its band recompute on — the band only changes when this changes.
    func firstRow(offset: CGFloat, count: Int) -> Int {
        guard count > 0, rowHeight > 0 else { return 0 }
        let raw = Int((offset / rowHeight).rounded(.down))
        return min(max(0, raw), count - 1)
    }

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

/// A programmatic scroll a `VirtualList` caller issues to reveal a row. `token` lets the same
/// `index` re-scroll — re-clicking the active playlist recenters on a file already positioned —
/// and it distinguishes an instant jump (a switch / re-click) from an animated reveal (keyboard move).
struct VirtualScrollCommand: Equatable {
    let index: Int
    let animated: Bool
    /// Any value whose change re-applies the command even when `index`/`animated` repeat.
    let token: AnyHashable
}

/// A fixed-row-height windowed list: it sizes its scroll content from `count` alone, renders only
/// the `VirtualWindow` band around the viewport, and positions by content offset. `initialTarget`
/// opens the list on a row with no travel (revealed only once positioned); `command` drives later
/// programmatic scrolls. The caller resolves each visible row lazily in `row` and must tolerate an
/// index momentarily out of its current range (return an empty view) while the sequence changes.
struct VirtualList<Row: View>: View {
    let count: Int
    let rowHeight: CGFloat
    /// Row to open at on first appearance (top-aligned, instant), or nil to open at the top.
    let initialTarget: Int?
    /// A later scroll to apply when it changes; nil issues nothing.
    let command: VirtualScrollCommand?
    @ViewBuilder let row: (Int) -> Row

    /// Rows built beyond each viewport edge so a fast flick never reveals a blank band.
    private static var overscan: Int { 8 }
    private var window: VirtualWindow { VirtualWindow(rowHeight: rowHeight, overscan: Self.overscan) }

    /// The live scroll offset, held in a reference box so the per-frame writes that track a drag
    /// don't invalidate `body` — read only when an animated reveal needs the current position.
    private final class ScrollOffset { var y: CGFloat = 0 }

    @State private var band: Range<Int> = 0..<0
    @State private var scrollPosition = ScrollPosition()
    @State private var offset = ScrollOffset()
    // Hidden until the first positioning pass runs, so the top never flashes before the list opens
    // on its target.
    @State private var isPositioned = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ScrollView {
                ZStack(alignment: .top) {
                    // A full-height spacer gives an honest scrollbar and content size without building
                    // a single row; the visible band is positioned into it by absolute offset.
                    Color.clear.frame(height: window.contentHeight(count: count))
                    ForEach(band, id: \.self) { index in
                        row(index)
                            .frame(height: rowHeight, alignment: .top)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(y: window.offsetY(of: index))
                    }
                }
            }
            .scrollPosition($scrollPosition)
            // The band changes only when the first visible row crosses a boundary, so this equatable
            // transform throttles the state write to boundary crossings, not every scrolled point.
            .onScrollGeometryChange(for: Range<Int>.self) { geo in
                window.visibleRange(offset: geo.contentOffset.y, height: geo.containerSize.height, count: count)
            } action: { _, newBand in
                band = newBand
            }
            // Track the raw offset off to the side (a reference write, not `@State`) so an animated
            // reveal can measure from where the list actually sits without re-rendering per frame.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                offset.y = y
            }
            .opacity(isPositioned ? 1 : 0)
            .onAppear { openInitial(height: height) }
            .onChange(of: command) { _, cmd in apply(cmd, height: height) }
        }
    }

    /// Positions on `initialTarget` (or the top) and builds its band before revealing, so the open
    /// shows no travel from the top.
    private func openInitial(height: CGFloat) {
        let y = window.targetOffset(index: initialTarget ?? 0, count: count, height: height)
        band = window.visibleRange(offset: y, height: height, count: count)
        if initialTarget != nil {
            scrollPosition.scrollTo(y: y)
            offset.y = y
        }
        // Reveal a runloop later, once the scroll offset has taken and the band is laid out.
        DispatchQueue.main.async { isPositioned = true }
    }

    /// Applies a later scroll: an animated *reveal* for a keyboard move — a minimal nearest-edge
    /// scroll from where the list sits, so the selection walks the viewport untouched until it
    /// crosses an edge — and an instant top-aligned jump otherwise, building the destination band
    /// first so the jump lands on real rows.
    private func apply(_ command: VirtualScrollCommand?, height: CGFloat) {
        guard let command else { return }
        if command.animated {
            let y = window.revealOffset(index: command.index, currentOffset: offset.y, height: height, count: count)
            withAnimation { scrollPosition.scrollTo(y: y) }
        } else {
            let y = window.targetOffset(index: command.index, count: count, height: height)
            band = window.visibleRange(offset: y, height: height, count: count)
            scrollPosition.scrollTo(y: y)
            offset.y = y
        }
    }
}
