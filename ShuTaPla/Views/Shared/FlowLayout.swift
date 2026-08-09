//
//  FlowLayout.swift
//  ShuTaPla
//
//  A wrapping layout for chips: places subviews left-to-right and wraps to the
//  next line when the next one would overflow the proposed width. Used by the
//  filter tag cloud, the tag editor's chips, and — nested one inside another — a
//  saved search's summary line, where each field's block flows as one unit.
//
//  The line breaking is `FlowLayoutPacking`, a pure function of the subview sizes:
//  measuring and placing must break lines identically, or a chip lands outside the
//  box its own measurement reserved.
//

import SwiftUI

/// Where a run of boxes lands when packed into lines of at most `maxWidth`.
nonisolated enum FlowLayoutPacking {
    struct Result: Equatable {
        /// Each box's origin, relative to the packed box's top-left, in input order.
        var origins: [CGPoint]
        /// What the lines occupy — as wide as the longest line, not as wide as `maxWidth`.
        var size: CGSize
    }

    static func pack(
        sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat
    ) -> Result {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for size in sizes {
            // The first box of a line is placed however wide it is: something has to go somewhere,
            // and one already clamped to `maxWidth` reports the height it wraps to.
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)

        return Result(origins: origins, size: CGSize(width: max(widest, 0), height: y + rowHeight))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    /// Each subview's intrinsic size, measured once per layout cycle. Both
    /// `sizeThatFits` and `placeSubviews` read it instead of re-measuring, so a chip
    /// field doesn't size every subview twice on each keystroke.
    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let packed = FlowLayoutPacking.pack(
            sizes: sizes(subviews, cache: cache, maxWidth: maxWidth),
            maxWidth: maxWidth, spacing: spacing, lineSpacing: lineSpacing
        )
        return CGSize(width: proposal.width ?? packed.size.width, height: packed.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = sizes(subviews, cache: cache, maxWidth: bounds.width)
        let packed = FlowLayoutPacking.pack(
            sizes: sizes, maxWidth: bounds.width, spacing: spacing, lineSpacing: lineSpacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + packed.origins[index].x,
                    y: bounds.minY + packed.origins[index].y
                ),
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    /// The cached sizes, with anything too wide for a whole line re-measured against one instead of
    /// left to overflow. A nested flow answers that narrower proposal by wrapping inside itself —
    /// which is what keeps a group placed as one subview from being split across two lines until it
    /// genuinely cannot fit on one.
    private func sizes(_ subviews: Subviews, cache: Cache, maxWidth: CGFloat) -> [CGSize] {
        zip(subviews, cache.sizes).map { subview, size in
            size.width <= maxWidth
                ? size
                : subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }
}
