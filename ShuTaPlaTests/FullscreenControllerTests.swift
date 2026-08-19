//
//  FullscreenControllerTests.swift
//  ShuTaPlaTests
//
//  `FullscreenController`'s decision core: what it does about a state that has been
//  asked for, given the window's actual state, whether a transition is animating and
//  whether the window is on screen — plus the sequences the notifications drive, from
//  a player session to a close and reopen. The animated AppKit transition itself needs
//  a real window and screen (and would create a Space), so it is only ever simulated
//  here by moving the harness's state and posting the window notifications.
//

import Testing
import AppKit
@testable import ShuTaPla

@Suite struct FullscreenControllerTests {

    /// At a window on screen: a request is carried out when the window isn't where it was asked to
    /// be, let go once it is, and held back while something is animating — AppKit drops a toggle
    /// issued mid-animation, and the style mask hasn't flipped yet either, so `actual` matching what
    /// is pending proves nothing until the transition lands. With nothing pending there is nothing
    /// to correct: the window is the user's.
    @Test(arguments: [
        // actual, pending, isTransitioning, expected
        (false, true as Bool?,  false, FullscreenController.Action.toggle),   // asked for fullscreen, windowed, idle
        (true,  false,          false, .toggle),                             // asked for windowed, fullscreen, idle
        (true,  true,           false, .settled),                            // already there → let it go
        (false, false,          false, .settled),
        (false, true,           true,  .wait),                               // animating → AppKit would drop it
        (true,  false,          true,  .wait),
        (true,  true,           true,  .wait),                               // matches, but mid-animation `actual` is stale
        (false, false,          true,  .wait),
        (false, nil,            false, .settled),                            // nothing asked for → nothing to do
        (true,  nil,            false, .settled),
    ])
    func actionHonorsStateAndTransition(
        actual: Bool, pending: Bool?, isTransitioning: Bool, expected: FullscreenController.Action
    ) {
        #expect(
            FullscreenController.action(actual: actual, pending: pending,
                                        isTransitioning: isTransitioning, isVisible: true)
                == expected
        )
    }

    /// A hidden window is never toggled, however far it is from what was asked for: the transition
    /// such a toggle starts never finishes, and the window stays mid-flight for the rest of the run.
    /// The request is kept, not dropped — `.wait`, so the next chance carries it out.
    @Test(arguments: [
        // actual, pending, isTransitioning
        (false, true,  false),
        (true,  false, false),
        (false, true,  true),
        (true,  false, true),
    ])
    func hiddenWindowIsNeverToggled(actual: Bool, pending: Bool, isTransitioning: Bool) {
        #expect(
            FullscreenController.action(actual: actual, pending: pending,
                                        isTransitioning: isTransitioning, isVisible: false) == .wait
        )
    }

    /// A window the user takes fullscreen themselves, outside player mode: their choice stands. The
    /// window is where it is, and nothing about the player has asked for anything else.
    @MainActor
    @Test func manualFullscreenOutsidePlayerModeIsLeftAlone() {
        let harness = WindowHarness()
        harness.show(true)
        harness.controller.setClaimed(false)        // manager mode, from launch

        harness.completeTransition(to: true)        // the user clicks the green button

        #expect(harness.toggles == 0)
        #expect(harness.isFullscreen)
    }

    /// The round trip through a player session from a windowed window: entering takes it fullscreen,
    /// leaving puts it back where it was.
    @MainActor
    @Test func aPlayerSessionTakesTheWindowFullscreenAndGivesItBack() {
        let harness = WindowHarness()
        harness.show(true)

        harness.controller.setClaimed(true)
        #expect(harness.toggles == 1)
        harness.completeTransition(to: true)
        #expect(harness.toggles == 1)               // arrived; nothing more is owed

        harness.controller.setClaimed(false)
        #expect(harness.toggles == 2)
        harness.completeTransition(to: false)
        #expect(harness.toggles == 2)
        #expect(!harness.isFullscreen)
    }

    /// The reported defect: a window taken fullscreen in manager mode, through a player session and
    /// out again, is still fullscreen — releasing the claim restores what the window was when player
    /// mode took it, not "windowed".
    @MainActor
    @Test func fullscreenTakenBeforePlayerModeSurvivesIt() {
        let harness = WindowHarness()
        harness.show(true)
        harness.isFullscreen = true                 // taken fullscreen by hand in manager mode

        harness.controller.setClaimed(true)         // entering player mode
        #expect(harness.toggles == 0)               // already where player mode wants it

        harness.controller.setClaimed(false)        // leaving player mode
        #expect(harness.toggles == 0)
        #expect(harness.isFullscreen)
    }

    /// Leaving fullscreen by hand *during* playback stands, and stands afterwards: the window the
    /// user chose becomes what releasing the claim restores, so ending the session doesn't put back
    /// a fullscreen they deliberately left.
    @MainActor
    @Test func leavingFullscreenDuringPlayerModeStands() {
        let harness = WindowHarness()
        harness.show(true)
        harness.isFullscreen = true                 // fullscreen already, from manager mode

        harness.controller.setClaimed(true)
        harness.completeTransition(to: false)       // the user presses Esc mid-playback
        #expect(harness.toggles == 0)               // not forced back in

        harness.controller.setClaimed(false)
        #expect(harness.toggles == 0)
        #expect(!harness.isFullscreen)
    }

    /// A claim released while its own enter transition is still animating: the toggle back is held
    /// until the animation lands (AppKit would drop one issued mid-flight), then issued, so a quick
    /// in-and-out of player mode ends windowed rather than stuck fullscreen.
    @MainActor
    @Test func aClaimReleasedMidTransitionIsCarriedOutWhenItSettles() {
        let harness = WindowHarness()
        harness.show(true)

        harness.controller.setClaimed(true)
        #expect(harness.toggles == 1)
        harness.beginTransition(to: true)           // AppKit starts animating

        harness.controller.setClaimed(false)        // straight back out of player mode
        #expect(harness.toggles == 1)               // held: nothing may be issued mid-animation

        harness.endTransition(to: true)
        #expect(harness.toggles == 2)               // the window settled; now the exit is issued
        harness.completeTransition(to: false)
        #expect(!harness.isFullscreen)
    }

    /// A claim taken while the window is hidden is carried out when the window appears. Nothing else
    /// re-states it — the mode is the same on the way in — so the request has to survive until a
    /// window that can act on it exists, whatever hid it: a launch that reaches player mode before
    /// the window is on screen, as much as a close.
    @MainActor
    @Test func aClaimMadeWhileHiddenIsCarriedOutWhenTheWindowAppears() {
        let harness = WindowHarness()
        harness.show(false)

        harness.controller.setClaimed(true)
        #expect(harness.toggles == 0)               // a hidden window strands the transition

        harness.show(true)
        harness.post(NSWindow.didBecomeKeyNotification)
        #expect(harness.toggles == 1)
    }

    /// Closing while fullscreen and reopening from the Dock, replaying the notification order macOS
    /// was measured to produce: `willClose` lands *before* the exit begins, the exit then runs to
    /// completion on an already-invisible window, and the window comes back windowed.
    ///
    /// Three things must hold. The exit finishing on the hidden window must toggle nothing — a
    /// toggle there starts an enter that never completes, leaving the transition flag raised for the
    /// rest of the run. The reopen must put back the fullscreen the close took away, since the
    /// single-instance `Window` scene hands back the same window and a close changes no mode, so
    /// `WindowFullscreenBridge` reports nothing and the player would sit windowed with nothing to
    /// correct it. And a later focus change must toggle nothing at all.
    @MainActor
    @Test func closingWhileFullscreenRestoresItOnReopen() {
        let harness = WindowHarness()
        harness.show(true)

        harness.controller.setClaimed(true)             // entering player mode
        #expect(harness.toggles == 1)
        harness.completeTransition(to: true)

        // Closing while fullscreen: the window goes invisible first, then AppKit exits fullscreen.
        harness.post(NSWindow.willCloseNotification)
        harness.show(false)
        harness.completeTransition(to: false)
        #expect(harness.toggles == 1)                   // nothing is toggled at a window nobody can see

        // Dock reopen: the same window is shown again and becomes key.
        harness.show(true)
        harness.post(NSWindow.didBecomeKeyNotification)
        #expect(harness.toggles == 2)
        harness.completeTransition(to: true)

        // Only what was owed is carried out — plain focus changes toggle nothing.
        harness.post(NSWindow.didBecomeKeyNotification)
        #expect(harness.toggles == 2)
    }

    /// Closing while the enter transition is still animating, replaying the measured order: the mask
    /// flips, `willClose` lands, the truncated enter completes, and AppKit then runs a full exit —
    /// all while the window still reports itself visible. The reopen must restore fullscreen just as
    /// a close from a settled fullscreen does; when Cmd-W happened to land shouldn't decide it.
    @MainActor
    @Test func closingMidEnterTransitionStillRestoresOnReopen() {
        let harness = WindowHarness()
        harness.show(true)

        harness.controller.setClaimed(true)             // entering player mode
        #expect(harness.toggles == 1)
        harness.beginTransition(to: true)               // willEnterFullScreen

        harness.isFullscreen = true                     // the mask flips before the close lands
        harness.post(NSWindow.willCloseNotification)
        harness.endTransition(to: true)                 // the truncated enter completes
        harness.completeTransition(to: false)           // AppKit exits fullscreen behind the close

        harness.post(NSWindow.didBecomeKeyNotification) // Dock reopen
        #expect(harness.toggles == 2)
    }

    /// A manager-mode fullscreen survives a player session that a close and reopen ran through the
    /// middle of. The exit AppKit runs behind the close is not the user leaving fullscreen, so it
    /// must not become what releasing the claim restores.
    @MainActor
    @Test func fullscreenTakenBeforePlayerModeSurvivesACloseWithinIt() {
        let harness = WindowHarness()
        harness.show(true)
        harness.isFullscreen = true                     // taken fullscreen by hand in manager mode

        harness.controller.setClaimed(true)             // entering player mode
        #expect(harness.toggles == 0)                   // already where player mode wants it

        harness.post(NSWindow.willCloseNotification)    // closed, and AppKit exits fullscreen behind it
        harness.show(false)
        harness.completeTransition(to: false)

        harness.show(true)                              // Dock reopen
        harness.post(NSWindow.didBecomeKeyNotification)
        #expect(harness.toggles == 1)
        harness.completeTransition(to: true)

        harness.controller.setClaimed(false)            // leaving player mode
        #expect(harness.toggles == 1)
        #expect(harness.isFullscreen)
    }

    /// A window the user left windowed before closing comes back windowed: the close took no
    /// fullscreen away, so nothing is owed on the way back.
    @MainActor
    @Test func closingWhileWindowedRestoresNothing() {
        let harness = WindowHarness()
        harness.show(true)
        harness.controller.setClaimed(true)
        harness.completeTransition(to: true)
        harness.completeTransition(to: false)           // the user leaves fullscreen by hand
        #expect(harness.toggles == 1)

        harness.post(NSWindow.willCloseNotification)
        harness.show(false)

        harness.show(true)
        harness.post(NSWindow.didBecomeKeyNotification)
        #expect(harness.toggles == 1)
        #expect(!harness.isFullscreen)
    }
}

/// One controller over a window whose state the test moves by hand: `isFullscreen` is what the
/// controller reads, `toggles` counts what it asks for, and the transition helpers play out what
/// AppKit would run — the `will…`/`did…` pair with the state flipping at the `did…`, which is the
/// order and the timing that were measured. The window itself stays windowed and far off screen,
/// fully transparent, so `show(true)` models a window on screen without putting anything on the
/// tester's: a real transition needs a screen and would create a Space.
@MainActor private final class WindowHarness {
    var isFullscreen = false
    var toggles = 0

    let window = NSWindow(
        contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true
    )

    lazy var controller = FullscreenController(
        window: window,
        isFullscreen: { [unowned self] _ in isFullscreen },
        toggle: { [unowned self] _ in toggles += 1 }
    )

    init() { window.alphaValue = 0 }

    func show(_ visible: Bool) { window.setIsVisible(visible) }

    func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: window)
    }

    func beginTransition(to fullscreen: Bool) {
        post(fullscreen ? NSWindow.willEnterFullScreenNotification
                        : NSWindow.willExitFullScreenNotification)
    }

    func endTransition(to fullscreen: Bool) {
        isFullscreen = fullscreen
        post(fullscreen ? NSWindow.didEnterFullScreenNotification
                        : NSWindow.didExitFullScreenNotification)
    }

    func completeTransition(to fullscreen: Bool) {
        beginTransition(to: fullscreen)
        endTransition(to: fullscreen)
    }
}
