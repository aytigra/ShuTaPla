//
//  WindowFullscreenBridgeTests.swift
//  ShuTaPlaTests
//
//  The bridge that turns player mode into a window fullscreen request: that each
//  change of the level reaches the hosting window exactly once, and that a repeat of
//  the same level reaches it not at all. The requesting view is built directly with a
//  stub in place of `FullscreenController`, whose transition needs a real screen and
//  would create a Space.
//

import Testing
import AppKit
@testable import ShuTaPla

@Suite struct WindowFullscreenBridgeTests {

    /// Entering player mode asks for fullscreen and leaving asks for windowed, while the repeated
    /// update calls SwiftUI makes for every re-render ask for nothing — a window the user took
    /// fullscreen by hand outside player mode has to stay that way.
    @MainActor
    @Test func onlyLevelChangesReachTheWindow() async {
        let window = offscreenWindow()
        let applied = Recorder()
        let view = WindowFullscreenBridge.FullscreenRequestingView { _, fullscreen in
            applied.values.append(fullscreen)
        }
        window.contentView?.addSubview(view)

        view.request(true)                          // entering player mode
        await settle()
        #expect(applied.values == [true])

        view.request(true)                          // a re-render with the mode unchanged
        await settle()
        #expect(applied.values == [true])

        view.request(false)                         // leaving player mode
        await settle()
        #expect(applied.values == [true, false])
    }

    /// A request made before the view is in a window isn't lost: attaching delivers it.
    @MainActor
    @Test func aRequestMadeBeforeAttachIsAppliedOnAttach() async {
        let window = offscreenWindow()
        let applied = Recorder()
        let view = WindowFullscreenBridge.FullscreenRequestingView { _, fullscreen in
            applied.values.append(fullscreen)
        }

        view.request(true)
        await settle()
        #expect(applied.values.isEmpty)             // nowhere to send it yet

        window.contentView?.addSubview(view)
        await settle()
        #expect(applied.values == [true])
    }

    /// What the window was last told is a fact about *that* window, so a view that moves to another
    /// one states its level again — the new window has never heard it.
    @MainActor
    @Test func movingToAnotherWindowRestatesTheLevel() async {
        let first = offscreenWindow()
        let second = offscreenWindow()
        let applied = Recorder()
        let view = WindowFullscreenBridge.FullscreenRequestingView { window, fullscreen in
            applied.windows.append(window)
            applied.values.append(fullscreen)
        }
        first.contentView?.addSubview(view)

        view.request(true)
        await settle()
        #expect(applied.values == [true])
        #expect(applied.windows.last === first)

        view.removeFromSuperview()
        second.contentView?.addSubview(view)
        await settle()
        #expect(applied.values == [true, true])
        #expect(applied.windows.last === second)
    }

    /// Far off screen, so nothing a test does puts anything in front of whoever is running it.
    @MainActor
    private func offscreenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
    }

    /// Lets the run-loop turn the bridge hops onto come around.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// A reference box so a test can collect the requests made from an escaping closure.
@MainActor private final class Recorder {
    var values: [Bool] = []
    var windows: [NSWindow] = []
}
