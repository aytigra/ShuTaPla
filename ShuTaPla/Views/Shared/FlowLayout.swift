//
//  FlowLayout.swift
//  ShuTaPla
//
//  A wrapping layout for chips: places subviews left-to-right and wraps to the
//  next line when the next one would overflow the proposed width. Used by the
//  filter tag cloud and the tag editor's chips.
//

import SwiftUI

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
        let sizes = cache.sizes

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)

        let height = y + rowHeight
        return CGSize(width: proposal.width ?? max(widest, 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let maxWidth = bounds.width
        let sizes = cache.sizes

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
