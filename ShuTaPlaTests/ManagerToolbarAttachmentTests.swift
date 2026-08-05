//
//  ManagerToolbarAttachmentTests.swift
//  ShuTaPlaTests
//
//  What leaving Manager mode has to take back off the window. The toolbar and the sidebar accessory
//  arrive together but do not belong to the window equally: the accessory is ours wherever the
//  window's toolbar ended up, while the toolbar may already have been replaced by another mode's.
//  These pin both halves against a bare window, with no split view or hosted panes involved.
//

import Testing
import AppKit
@testable import ShuTaPla

@MainActor
@Suite struct ManagerToolbarAttachmentTests {

    func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
    }

    func makeAccessory() -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 28))
        return accessory
    }

    @Test func detachTakesBackBothTheToolbarAndTheAccessory() {
        let window = makeWindow()
        let toolbar = NSToolbar(identifier: "ManagerToolbar")
        let accessory = makeAccessory()
        window.toolbar = toolbar
        window.titleVisibility = .hidden
        window.addTitlebarAccessoryViewController(accessory)

        ManagerSplitViewController.detachChrome(from: window, toolbar: toolbar, accessory: accessory)

        #expect(window.toolbar == nil)
        #expect(window.titleVisibility == .visible)
        #expect(!window.titlebarAccessoryViewControllers.contains(accessory))
    }

    @Test func theAccessoryGoesEvenWhenAnotherToolbarHasAlreadyReplacedOurs() {
        // The failure this guards: the sidebar's controls following Welcome or Player onto their
        // titlebar, which is the whole reason detaching exists.
        let window = makeWindow()
        let ours = NSToolbar(identifier: "ManagerToolbar")
        let accessory = makeAccessory()
        window.toolbar = ours
        window.addTitlebarAccessoryViewController(accessory)
        window.toolbar = NSToolbar(identifier: "SomeOtherToolbar")

        ManagerSplitViewController.detachChrome(from: window, toolbar: ours, accessory: accessory)

        #expect(!window.titlebarAccessoryViewControllers.contains(accessory))
    }

    @Test func aToolbarThatIsNoLongerOursIsLeftAlone() {
        // Clearing it would strip the mode that took over, which is not ours to do.
        let window = makeWindow()
        let ours = NSToolbar(identifier: "ManagerToolbar")
        let theirs = NSToolbar(identifier: "SomeOtherToolbar")
        window.toolbar = theirs

        ManagerSplitViewController.detachChrome(from: window, toolbar: ours, accessory: nil)

        #expect(window.toolbar === theirs)
    }
}
