//
//  ClickOutsideMonitorTests.swift
//  ShuTaPlaTests
//
//  Which clicks the monitor counts as its own. The rect it tests against is the backing view's
//  bounds in AppKit coordinates (y up), grown over the control above it and the panel below it —
//  the part that decides whether a panel closes, and the part no click can be simulated for.
//

import Testing
import AppKit
@testable import ShuTaPla

@Suite struct ClickOutsideMonitorTests {
    /// A backing view 100 wide and 60 tall, with a 24-tall control above it (the `Searches` button)
    /// and an 80-tall panel below it (the suggestion dropdown).
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)
    private let above: CGFloat = 24
    private let below: CGFloat = 80

    private func isInside(_ point: CGPoint, above: CGFloat = 0, below: CGFloat = 0) -> Bool {
        ClickOutsideMonitor.insideRect(bounds, above: above, below: below).contains(point)
    }

    @Test func theViewsOwnBoundsAreInside() {
        #expect(isInside(CGPoint(x: 50, y: 30), above: above, below: below))
        #expect(isInside(CGPoint(x: 50, y: 30)))
    }

    @Test func theControlAboveTheViewIsInside() {
        // Its own mouse-down must not dismiss the panel that the control's action then toggles
        // back open.
        #expect(isInside(CGPoint(x: 50, y: 70), above: above))
    }

    @Test func thePanelBelowTheViewIsInside() {
        #expect(isInside(CGPoint(x: 50, y: -50), below: below))
    }

    @Test func pastEitherExtensionIsOutside() {
        #expect(!isInside(CGPoint(x: 50, y: 90), above: above, below: below))
        #expect(!isInside(CGPoint(x: 50, y: -90), above: above, below: below))
    }

    @Test func neitherExtensionReachesTheOtherSide() {
        #expect(!isInside(CGPoint(x: 50, y: 70), below: below))
        #expect(!isInside(CGPoint(x: 50, y: -50), above: above))
    }

    @Test func besideTheViewIsOutside() {
        #expect(!isInside(CGPoint(x: 140, y: 30), above: above, below: below))
        #expect(!isInside(CGPoint(x: -10, y: 30), above: above, below: below))
    }
}
