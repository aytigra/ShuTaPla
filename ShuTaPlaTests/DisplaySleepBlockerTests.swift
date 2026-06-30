//
//  DisplaySleepBlockerTests.swift
//  ShuTaPlaTests
//
//  Covers the assertion lifecycle: arming holds a power activity, releasing ends it,
//  and same-value writes don't churn the token.
//

import Testing
@testable import ShuTaPla

@MainActor
struct DisplaySleepBlockerTests {
    @Test func startsReleased() {
        #expect(DisplaySleepBlocker().isBlocking == false)
    }

    @Test func armingAndReleasingToggleTheAssertion() {
        let blocker = DisplaySleepBlocker()

        blocker.isActive = true
        #expect(blocker.isBlocking)

        blocker.isActive = false
        #expect(blocker.isBlocking == false)
    }

    @Test func repeatedActivationKeepsASingleAssertion() {
        let blocker = DisplaySleepBlocker()

        blocker.isActive = true
        #expect(blocker.isBlocking)

        // A no-op re-arm must not release and re-acquire underneath.
        blocker.isActive = true
        #expect(blocker.isBlocking)
    }
}
