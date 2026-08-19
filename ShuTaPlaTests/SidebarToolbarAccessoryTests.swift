//
//  SidebarToolbarAccessoryTests.swift
//  ShuTaPlaTests
//
//  *When* the sidebar accessory re-reads its geometry, and against which coordinate space — the half
//  `SidebarToolbarLayoutTests` cannot see: that suite pins what `resolve` returns for the inputs it is
//  handed, while everything here is about the container's width being re-resolved at all, and from
//  numbers that mean the same thing.
//
//  The hierarchy the harness builds is the measured one, not an idealized one. AppKit puts a titlebar
//  accessory inside an `NSTitlebarAccessoryClipView` and leaves it at the clip's origin permanently:
//  a trace of a real full-screen session showed the accessory's own frame fixed at (0,0 152x52)
//  throughout while the clip slid 88 → 67 → 43 → 0 and back, and showed the accessory hosted in an
//  `NSToolbarFullScreenWindow` while the split view it measures against stayed in the app's window.
//  So the harness moves a clip view rather than the container, and re-hosts it in a second window for
//  the full-screen case — the two facts that decide whether the trigger and the arithmetic are right.
//

import Testing
import AppKit
@testable import ShuTaPla

@MainActor
@Suite struct SidebarToolbarAccessoryTests {

    /// The reported defect, as a sequence: the `+` sits on the divider windowed, and has to still be
    /// there through the full-screen reflow and through every hide and reveal of the traffic lights
    /// that follows. Nothing but the clip's origin moves after the first step — the divider stands
    /// still throughout — so any step that comes out wrong is a container width that was resolved for
    /// a leading edge the accessory no longer has.
    @Test func thePlusHoldsTheDividerThroughTheFullScreenReflow() {
        let harness = AccessoryHarness()
        harness.slideClip(to: 88)                       // windowed: clear of the traffic lights
        harness.accessory.updateGeometry()              // the mount-time pass, from `syncSidebarControls`
        #expect(harness.plusTrailingEdge == harness.dividerEdge)

        harness.slideClip(to: 0)                        // full screen: the lights go away
        #expect(harness.plusTrailingEdge == harness.dividerEdge)

        for step in [13, 43, 67, 88] as [CGFloat] {     // the titlebar is hovered: the lights slide in
            harness.slideClip(to: step)
            #expect(harness.plusTrailingEdge == harness.dividerEdge)
        }

        harness.slideClip(to: 0)                        // and auto-hide again
        #expect(harness.plusTrailingEdge == harness.dividerEdge)
    }

    /// Full screen hands the whole titlebar to a separate `NSToolbarFullScreenWindow`, so the
    /// accessory and the split view it spans to end up in two different windows. Their window
    /// coordinates then describe different origins, and the only space both are stated in is the
    /// screen's — pinned here with the second window deliberately offset, since two windows agreeing
    /// on an origin is a coincidence of the layout, not something the measurement may rest on.
    @Test func aReHostedAccessoryStillMeasuresToTheDivider() {
        let harness = AccessoryHarness()
        harness.slideClip(to: 88)
        harness.accessory.updateGeometry()

        harness.reHostInFullScreenTitlebar()
        #expect(harness.plusTrailingEdge == harness.dividerEdge)

        harness.slideClip(to: 0)
        #expect(harness.plusTrailingEdge == harness.dividerEdge)
    }

    /// The other move: the divider goes and the accessory stays. It is the split view's notification
    /// that carries this one — a drag moves nothing in the titlebar, so watching the clip sees none
    /// of it.
    @Test func aDividerDragStillCarriesThePlusWithIt() {
        let harness = AccessoryHarness()
        harness.slideClip(to: 88)
        harness.accessory.updateGeometry()

        harness.dragDivider(to: 720)
        #expect(harness.plusTrailingEdge == harness.dividerEdge)

        harness.dragDivider(to: 520)
        #expect(harness.plusTrailingEdge == harness.dividerEdge)
    }

    /// A geometry pass resizes the container, and AppKit resizes the clip to follow — so the pass has
    /// a way back into itself. It has to stop there: the second read finds the same leading edge and
    /// the same divider, and `fit` sees the width it just wrote.
    @Test func aPassThatResizesTheContainerSettlesInsteadOfFeedingItself() {
        let harness = AccessoryHarness()
        harness.slideClip(to: 88)
        harness.accessory.updateGeometry()

        harness.accessory.resetReads()
        harness.slideClip(to: 0)
        #expect(harness.accessory.reads <= 2)
        #expect(harness.plusTrailingEdge == harness.dividerEdge)
    }

    /// A collapsed sidebar takes the accessory out of the window entirely, and an unmounted accessory
    /// has no geometry to describe — its leading edge is meaningless off screen, and writing the
    /// sidebar's minimum thickness from it would move a pane the user is mid-collapse.
    @Test func anUnmountedAccessoryReadsNothing() {
        let harness = AccessoryHarness()
        harness.slideClip(to: 88)
        harness.accessory.updateGeometry()

        harness.unmount()
        harness.accessory.resetReads()
        harness.slideClip(to: 0)
        harness.dragDivider(to: 720)
        #expect(harness.accessory.reads == 0)
    }
}

/// A `SidebarToolbarAccessory` whose divider the test writes directly, and which counts what it
/// reads. A real split view reports a divider only once it is laid out in a window on screen, and
/// what is under test is when the accessory looks — not the split view's arithmetic.
@MainActor private final class ScriptedAccessory: SidebarToolbarAccessory {
    /// Both in screen coordinates, like the real one: the divider sits `AccessoryHarness.dividerInset`
    /// into an app window that starts at `windowX`.
    var scriptedDividerX = AccessoryHarness.appWindowX + AccessoryHarness.dividerInset
    private(set) var reads = 0

    override var paneGeometry: (dividerX: CGFloat, windowX: CGFloat)? {
        reads += 1
        return (scriptedDividerX, AccessoryHarness.appWindowX)
    }

    func resetReads() { reads = 0 }
}

/// The measured hierarchy: a clip view holding the container at its origin, which is where AppKit
/// keeps it. `slideClip` is the titlebar reflowing, `dragDivider` is the split view resizing beneath
/// a stationary titlebar, and `reHostInFullScreenTitlebar` is full screen moving the whole titlebar
/// into its own window. Neither window is ever ordered in and nothing draws — the container only has
/// to be *in* a window, so that its leading edge converts to screen space and its layout pass runs.
@MainActor private final class AccessoryHarness {
    /// Deliberately not the screen origin, so a measurement that quietly stayed in window coordinates
    /// reads 200 short of one that reached screen space.
    static let appWindowX: CGFloat = 200
    /// How far into the app window the sidebar divider sits.
    static let dividerInset: CGFloat = 400

    let window = NSWindow(
        contentRect: NSRect(x: appWindowX, y: 0, width: 1512, height: 949),
        styleMask: [.titled], backing: .buffered, defer: true
    )
    /// Where full screen re-hosts the titlebar. At a different origin from the app window on purpose:
    /// the two agree on one in the layout that was traced, and nothing here may depend on that.
    let fullScreenTitlebarWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 897, width: 1512, height: 52),
        styleMask: [.borderless], backing: .buffered, defer: true
    )
    let clip = NSView(frame: NSRect(x: 0, y: 0, width: 152, height: 52))
    let splitViewController: NSSplitViewController
    let scope: NSButton
    let plus: NSButton
    let container: SidebarToolbarAccessoryView
    let accessory: ScriptedAccessory

    /// Stand-ins for the hosted SwiftUI controls: real AppKit views, so the container measures and
    /// places them exactly as it does the real pair, without a SwiftUI environment to build.
    init() {
        let split = NSSplitViewController(nibName: nil, bundle: nil)
        let scope = NSButton(title: "Scope", target: nil, action: nil)
        let plus = NSButton(title: "+", target: nil, action: nil)
        let container = SidebarToolbarAccessoryView(scope: scope, plus: plus)
        self.splitViewController = split
        self.scope = scope
        self.plus = plus
        self.container = container
        self.accessory = ScriptedAccessory(container: container, splitViewController: split)
        clip.addSubview(container)
        window.contentView?.addSubview(clip)
    }

    /// Where the `+` is supposed to land at every step: its inset short of the sidebar divider.
    var dividerEdge: CGFloat {
        accessory.scriptedDividerX - SidebarToolbarLayout.plusTrailingInset
    }

    /// Where it actually lands, in screen coordinates. Its trailing edge rather than its origin, so
    /// the assertion states what the control is for — sitting on the divider — instead of restating
    /// the layout's arithmetic over a measured button width.
    var plusTrailingEdge: CGFloat {
        container.layoutSubtreeIfNeeded()
        let inWindow = plus.convert(NSPoint(x: plus.bounds.maxX, y: 0), to: nil)
        return plus.window?.convertPoint(toScreen: inWindow).x ?? .nan
    }

    /// The titlebar reflowing: AppKit slides the clip and leaves the container at its origin.
    func slideClip(to x: CGFloat) {
        clip.setFrameOrigin(NSPoint(x: x, y: 0))
    }

    /// The divider moving beneath it — a drag, or a frame of a collapse animation.
    func dragDivider(to x: CGFloat) {
        accessory.scriptedDividerX = x
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification, object: splitViewController.splitView
        )
    }

    /// Entering full screen: the titlebar, and the accessory with it, moves to its own window.
    func reHostInFullScreenTitlebar() {
        fullScreenTitlebarWindow.contentView?.addSubview(clip)
    }

    /// What collapsing the sidebar does: the accessory leaves the window altogether.
    func unmount() {
        clip.removeFromSuperview()
    }
}
