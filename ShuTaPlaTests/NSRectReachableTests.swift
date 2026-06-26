//
//  NSRectReachableTests.swift
//  ShuTaPlaTests
//
//  The pure decision behind off-screen window-frame restoration: whether a persisted frame
//  still overlaps a screen enough to be grabbable, given the current display layout.
//

import Testing
import Foundation
import CoreGraphics
@testable import ShuTaPla

@Suite struct NSRectReachableTests {

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func frameFullyOnScreenIsReachable() {
        #expect(NSRect(x: 100, y: 100, width: 800, height: 600).isReachable(onAnyOf: [screen]))
    }

    @Test func frameFullyOffEveryScreenIsNotReachable() {
        // Saved on a second monitor that is no longer attached.
        #expect(!NSRect(x: 5000, y: 5000, width: 800, height: 600).isReachable(onAnyOf: [screen]))
    }

    @Test func frameWithOnlyASliverOnScreenIsNotReachable() {
        // Only ~10pt pokes in from the right edge — not enough to grab the title bar.
        #expect(!NSRect(x: 1430, y: 100, width: 800, height: 600).isReachable(onAnyOf: [screen]))
    }

    @Test func frameLargerThanScreenButCenteredIsReachable() {
        #expect(NSRect(x: -100, y: -50, width: 1600, height: 1000).isReachable(onAnyOf: [screen]))
    }

    @Test func reachableOnTheSecondOfMultipleScreens() {
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(NSRect(x: 1600, y: 100, width: 800, height: 600).isReachable(onAnyOf: [screen, second]))
    }

    @Test func noScreensIsNotReachable() {
        #expect(!NSRect(x: 0, y: 0, width: 800, height: 600).isReachable(onAnyOf: []))
    }
}
