//
//  FullscreenControllerTests.swift
//  ShuTaPlaTests
//
//  The pure decision core of `FullscreenController`: whether to issue a fullscreen
//  toggle given the window's actual state, the desired state, and whether a
//  transition is animating. The animated AppKit transition itself needs a real
//  window and screen, so only this reconcile rule is unit-tested.
//

import Testing
@testable import ShuTaPla

@Suite struct FullscreenControllerTests {

    /// A toggle is issued only when the window isn't already where it's wanted and nothing is
    /// animating — matching desired needs no toggle, and a mid-animation toggle is held back
    /// (AppKit drops it and strands the window).
    @Test(arguments: [
        // actual, desired, isTransitioning, expectToggle
        (false, true,  false, true),   // want fullscreen, idle, currently windowed → toggle
        (true,  false, false, true),   // want windowed, idle, currently fullscreen → toggle
        (true,  true,  false, false),  // already fullscreen as wanted → nothing
        (false, false, false, false),  // already windowed as wanted → nothing
        (false, true,  true,  false),  // wants fullscreen but a transition is animating → wait
        (true,  false, true,  false),  // wants windowed but a transition is animating → wait
        (true,  true,  true,  false),  // matches desired, animating → nothing
        (false, false, true,  false),  // matches desired, animating → nothing
    ])
    func shouldToggleHonorsStateAndTransition(
        actual: Bool, desired: Bool, isTransitioning: Bool, expectToggle: Bool
    ) {
        #expect(
            FullscreenController.shouldToggle(actual: actual, desired: desired, isTransitioning: isTransitioning)
                == expectToggle
        )
    }
}
