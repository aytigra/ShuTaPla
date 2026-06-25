//
//  NSWindow+Fullscreen.swift
//  ShuTaPla
//
//  Window-level fullscreen control for the player. macOS's `toggleFullScreen`
//  runs an asynchronous, animated transition; a second toggle issued while one is
//  still animating is dropped by AppKit and strands the window out of sync. The
//  controller here keeps the *desired* state authoritative and defers each change
//  until the running animation settles, so a quick enter→exit (or the reverse)
//  lands windowed-or-fullscreen as asked, with no flicker or stuck state. The
//  `FullscreenView` bridge expresses that desire as player mode comes and goes.
//

import AppKit

extension NSWindow {
    /// Whether the window is currently in macOS fullscreen.
    var isFullscreen: Bool { styleMask.contains(.fullScreen) }

    /// The window's lazily-created fullscreen controller, retained for the window's lifetime so it
    /// can finish reconciling a transition even after the view that requested it has torn down.
    var fullscreenController: FullscreenController {
        if let existing = objc_getAssociatedObject(self, &fullscreenControllerKey) as? FullscreenController {
            return existing
        }
        let controller = FullscreenController(window: self)
        objc_setAssociatedObject(self, &fullscreenControllerKey, controller, .OBJC_ASSOCIATION_RETAIN)
        return controller
    }
}

private nonisolated(unsafe) var fullscreenControllerKey = 0

/// Drives one window between windowed and fullscreen, keeping the requested state authoritative
/// across macOS's animated transitions. Callers set the desired state; the controller issues at
/// most one `toggleFullScreen` per settled transition to close the gap, dropping nothing and never
/// toggling mid-animation (which AppKit would ignore).
@MainActor
final class FullscreenController: NSObject {
    private weak var window: NSWindow?

    /// The state the window should be in. Authoritative: a request that arrives mid-animation is
    /// remembered here and applied once the running transition finishes.
    private var desired = false

    /// True between a `will…FullScreen` and its matching `did…FullScreen` — the window is
    /// animating and must not be toggled again until it settles.
    private var isTransitioning = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(transitionWillStart),
                           name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(transitionWillStart),
                           name: NSWindow.willExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(transitionDidFinish),
                           name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(transitionDidFinish),
                           name: NSWindow.didExitFullScreenNotification, object: window)
    }

    /// Requests the window be fullscreen (or windowed). Reconciles right away when idle; otherwise
    /// the desire is applied when the in-flight animation finishes.
    func setDesired(_ fullscreen: Bool) {
        desired = fullscreen
        reconcile()
    }

    /// Issues a toggle only when one is warranted — the window isn't already where it's wanted and
    /// nothing is animating.
    private func reconcile() {
        guard let window,
              Self.shouldToggle(actual: window.isFullscreen, desired: desired, isTransitioning: isTransitioning)
        else { return }
        window.toggleFullScreen(nil)
    }

    /// The pure decision: a toggle moves `actual` toward `desired`, but never while a transition is
    /// animating (AppKit drops a mid-flight toggle and strands the window). `nonisolated` — it
    /// reads no actor state, so callers (and tests) need not hop to the main actor.
    nonisolated static func shouldToggle(actual: Bool, desired: Bool, isTransitioning: Bool) -> Bool {
        !isTransitioning && actual != desired
    }

    @objc private func transitionWillStart() { isTransitioning = true }

    @objc private func transitionDidFinish() {
        isTransitioning = false
        reconcile()   // catch up to a desire that changed while this animation ran
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
