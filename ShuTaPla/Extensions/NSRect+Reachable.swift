//
//  NSRect+Reachable.swift
//  ShuTaPla
//
//  A persisted window frame is restored verbatim at launch, but the display layout can change
//  between sessions — a second monitor unplugged, a screen swapped for a smaller one. A frame
//  saved on a since-removed display falls entirely (or all but a sliver) outside every screen, and
//  restoring it would strand the window where its title bar can't be grabbed. `isReachable` is the
//  pure guard the window-frame bridge consults before restoring.
//

import Foundation
import CoreGraphics

extension NSRect {
    /// Whether enough of this frame overlaps one of `visibleFrames` for the window to stay
    /// reachable — its title bar grabbable. True when the intersection with some screen is at
    /// least `minimumVisible` in each axis; a frame fully off-screen, or showing only a thin
    /// sliver, is not reachable. A window larger than every screen still counts, since its
    /// overlap with a containing screen is the screen itself.
    ///
    /// `nonisolated`, and the scan is a plain `for` loop rather than `.contains { }`: under the
    /// target's `NonisolatedNonsendingByDefault`, a closure here would inherit the caller's actor
    /// isolation and trap a non-`@MainActor` test's queue assertion.
    nonisolated func isReachable(onAnyOf visibleFrames: [NSRect],
                                 minimumVisible: NSSize = NSSize(width: 120, height: 40)) -> Bool {
        for screen in visibleFrames {
            let overlap = screen.intersection(self)
            if overlap.width >= minimumVisible.width && overlap.height >= minimumVisible.height {
                return true
            }
        }
        return false
    }
}
