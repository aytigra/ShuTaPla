//
//  ImageTransformTests.swift
//  ShuTaPlaTests
//
//  F15 — the pure pan/zoom math on `ImageTransform`. `zoomed(by:about:)` must keep the picture
//  point under the pinch fixed (screen map `scale·b + offset`), and `clamped(frame:viewport:)`
//  must bound the offset so the picture never strands off the viewport.
//

import Testing
import Foundation
import CoreGraphics
@testable import ShuTaPla

@Suite struct ImageTransformTests {

    private static let minScale: CGFloat = 0.1

    /// Screen position of the base-local point `b` under transform `t`: `offset + scale·b`.
    private func screen(of b: CGSize, under t: ImageTransform) -> CGSize {
        CGSize(width: t.offset.width + t.scale * b.width,
               height: t.offset.height + t.scale * b.height)
    }

    /// The defining invariant: whatever picture point sits under the pinch centre `c` before the
    /// zoom must still sit under `c` after it — including from an already zoomed (`s0 ≠ 1`) or
    /// panned (`O0 ≠ 0`) state, where the old commit (`O0 + c·(1−s_new)`) drifts.
    @Test(arguments: [
        (CGFloat(2), CGSize(width: 100, height: 0), CGSize(width: 400, height: 0), CGFloat(1.5)),
        (1.0, .zero, CGSize(width: 400, height: 200), 2.0),
        (0.5, CGSize(width: -50, height: 30), CGSize(width: -200, height: 150), 3.0),
        (2.5, CGSize(width: 40, height: -80), CGSize(width: 120, height: -90), 0.6),
    ] as [(CGFloat, CGSize, CGSize, CGFloat)])
    func pinchKeepsPointUnderFingersFixed(s0: CGFloat, o0: CGSize, c: CGSize, m: CGFloat) {
        let t = ImageTransform(offset: o0, scale: s0)
        // Base-local point currently under the pinch centre.
        let b = CGSize(width: (c.width - o0.width) / s0, height: (c.height - o0.height) / s0)
        let zoomed = t.zoomed(by: m, about: c, minScale: Self.minScale)
        let after = screen(of: b, under: zoomed)
        #expect(abs(after.width - c.width) < 0.001)
        #expect(abs(after.height - c.height) < 0.001)
    }

    /// The min-scale floor still keeps the pinch point fixed: a hard zoom-out clamps `scale`, and
    /// the offset must use the effective (post-floor) factor so the invariant survives.
    @Test func flooredZoomStillKeepsPinchPointFixed() {
        let t = ImageTransform(offset: CGSize(width: 60, height: -20), scale: 0.2)
        let c = CGSize(width: 150, height: -100)
        let b = CGSize(width: (c.width - t.offset.width) / t.scale,
                       height: (c.height - t.offset.height) / t.scale)
        let zoomed = t.zoomed(by: 0.01, about: c, minScale: Self.minScale)  // 0.2·0.01 → floored to 0.1
        #expect(zoomed.scale == Self.minScale)
        let after = screen(of: b, under: zoomed)
        #expect(abs(after.width - c.width) < 0.001)
        #expect(abs(after.height - c.height) < 0.001)
    }

    /// Larger than the viewport: pan is bounded to the picture edge (`(scale·F − V)/2`), no margin.
    @Test func clampBoundsPanToEdgeWhenLargerThanViewport() {
        let frame = CGSize(width: 1000, height: 500)
        let viewport = CGSize(width: 800, height: 600)
        let t = ImageTransform(offset: CGSize(width: 999, height: 0), scale: 2)
        let clamped = t.clamped(frame: frame, viewport: viewport)
        #expect(clamped.offset.width == 600)   // (2·1000 − 800)/2
        #expect(clamped.offset.height == 0)    // 2·500=1000 > 600 → limit 200, 0 in range
        #expect(clamped.scale == 2)
    }

    /// Smaller than the viewport (zoomed out): the bound is 0, so a stranded offset recenters.
    @Test func clampRecentersWhenSmallerThanViewport() {
        let frame = CGSize(width: 1000, height: 500)
        let viewport = CGSize(width: 800, height: 600)
        let t = ImageTransform(offset: CGSize(width: 500, height: -400), scale: 0.5)
        let clamped = t.clamped(frame: frame, viewport: viewport)
        #expect(clamped.offset == .zero)
    }
}
