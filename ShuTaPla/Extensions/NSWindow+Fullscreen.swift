//
//  NSWindow+Fullscreen.swift
//  ShuTaPla
//
//  Window-level fullscreen control for the player. macOS's `toggleFullScreen`
//  runs an asynchronous, animated transition, and it only takes at a window that
//  is settled and on screen — one issued mid-animation is dropped by AppKit, one
//  issued at a hidden window starts a transition that never finishes. So a change
//  asked for here is owed until the window is seen to have made it, and a quick
//  enter→exit (or the reverse), or a close and reopen, still lands as asked with no
//  flicker or stuck state.
//
//  What is never owed is left alone. Player mode *claims* fullscreen while it runs
//  — `WindowFullscreenBridge` takes and releases the claim as the mode comes and
//  goes — and at every other moment the window belongs to the user: a fullscreen
//  they choose themselves stands, in player mode or out of it.
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

/// Drives one window between windowed and fullscreen across macOS's animated transitions. A caller
/// claims fullscreen for as long as it needs it; the controller issues at most one `toggleFullScreen`
/// per settled transition to close the gap, drops nothing, and never toggles mid-animation (which
/// AppKit would ignore). Outside a claim — and inside one, for anything the user does themselves —
/// it follows the window rather than correcting it.
@MainActor
final class FullscreenController: NSObject {
    private weak var window: NSWindow?

    /// A state that has been asked for and not yet reached. `nil` means nothing is owed, and nothing
    /// owed means nothing is corrected: the window is the user's. Kept until the window is *observed*
    /// in that state, so a request that cannot be carried out at the time — mid-animation, or at a
    /// hidden window — is carried out at the next opportunity instead of being dropped.
    private var pending: Bool?

    /// What the window was when the claim was taken, and what releasing it restores. Non-nil exactly
    /// while a claim is held.
    private var baseline: Bool?

    /// What the window is owed when it comes back, held from `willClose` until the reopen. Kept apart
    /// from `pending` because the close's own transitions run in between and would consume it: a
    /// close landing mid-enter is followed by that truncated enter completing — which finds the
    /// window where it was asked to be and settles the request — and then by AppKit's exit, with
    /// nothing owed left to notice the loss.
    private var restoreOnReopen: Bool?

    /// True between a `will…FullScreen` and its matching `did…FullScreen` — the window is
    /// animating and must not be toggled again until it settles.
    private var isTransitioning = false

    /// How the window's state is read and how a toggle is carried out. Only tests substitute them:
    /// an actual transition needs a real screen and would create a Space, so they count the toggles
    /// instead of running them — and since the decision is made against the window's *actual* state,
    /// a test also has to be able to move it.
    private let isFullscreen: (NSWindow) -> Bool
    private let toggle: (NSWindow) -> Void

    init(
        window: NSWindow,
        isFullscreen: @escaping (NSWindow) -> Bool = { $0.isFullscreen },
        toggle: @escaping (NSWindow) -> Void = { $0.toggleFullScreen(nil) }
    ) {
        self.window = window
        self.isFullscreen = isFullscreen
        self.toggle = toggle
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
        center.addObserver(self, selector: #selector(windowWillClose),
                           name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidBecomeKey),
                           name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// Claims the window's fullscreen state, or releases the claim. Taking it asks for fullscreen
    /// and remembers what the window was; releasing it asks for that back. Stating the level the
    /// claim is already at changes nothing, so a caller may repeat itself freely.
    func setClaimed(_ claimed: Bool) {
        switch (claimed, baseline) {
        case (true, nil):
            baseline = window.map(isFullscreen) ?? false
            request(true)
        case (false, let restore?):
            baseline = nil
            request(restore)
        default:
            break   // the claim is already held, or already released
        }
    }

    /// Records what is owed and carries it out as far as the window allows.
    private func request(_ fullscreen: Bool) {
        pending = fullscreen
        reconcile()
    }

    /// Acts on what is owed, or waits. Retries rather than dropping: while a request stands, every
    /// event that can unblock it — the end of a transition, or the window becoming key again —
    /// comes back through here to re-derive the decision from what is true by then. The request is
    /// let go only once the window is seen in the state it asked for, whoever put it there.
    private func reconcile() {
        guard let window else { return }
        switch Self.action(actual: isFullscreen(window), pending: pending,
                           isTransitioning: isTransitioning, isVisible: window.isVisible) {
        case .toggle: toggle(window)
        case .settled: pending = nil
        case .wait: break
        }
    }

    /// What `reconcile` does about the window's state: carry the request out, wait for a better
    /// moment, or let it go as satisfied. `nonisolated` alongside the `action` that returns it, so
    /// comparing two of them needs no hop to the main actor.
    nonisolated enum Action { case toggle, wait, settled }

    /// The pure decision. A toggle moves `actual` toward what is pending, but only at a window that
    /// is settled and on screen: AppKit drops one issued mid-animation, and one issued at a hidden
    /// window starts a transition that never finishes (no `did…FullScreen` ever lands, so the window
    /// is stranded mid-flight for the rest of the run). Mid-animation the reading is stale anyway —
    /// the style mask flips at the `did…`, not when the animation starts — so a transition in flight
    /// is a wait and never a `.settled`. With nothing pending there is nothing to do: an unrequested
    /// state is the user's, not a gap to close. `nonisolated` — it reads no actor state, so callers
    /// (and tests) need not hop to the main actor.
    nonisolated static func action(
        actual: Bool, pending: Bool?, isTransitioning: Bool, isVisible: Bool
    ) -> Action {
        guard let pending else { return .settled }
        if isTransitioning { return .wait }
        if actual == pending { return .settled }
        return isVisible ? .toggle : .wait
    }

    @objc private func transitionWillStart() { isTransitioning = true }

    /// A transition that finishes with nothing pending is one the user ran themselves. While a claim
    /// is held that redefines what releasing it restores: leaving fullscreen by hand during playback
    /// must not be undone the moment player mode ends. A close is the exception — the exit AppKit
    /// runs behind one also lands with nothing pending, and taking it for the user's would destroy
    /// the fullscreen the claim exists to give back. `restoreOnReopen` is non-nil exactly across a
    /// close, which is exactly the span where a transition is not the user's.
    @objc private func transitionDidFinish() {
        isTransitioning = false
        if pending == nil, restoreOnReopen == nil, baseline != nil, let window {
            baseline = isFullscreen(window)
        }
        reconcile()   // catch up to a request that arrived while this animation ran
    }

    /// A close takes the window's fullscreen away with nobody having asked — AppKit exits fullscreen
    /// behind it and does not put it back on the way in — so what the window will be owed is recorded
    /// here, before any of that runs. A request still in flight is what the reopen owes: it is what
    /// was wanted, and the close only interrupted it. With nothing owed, the window's own state is
    /// what it comes back to, so a user who left fullscreen by hand before closing gets a windowed
    /// window and one who released the claim mid-transition is not overridden into fullscreen.
    @objc private func windowWillClose() {
        guard let window else { return }
        restoreOnReopen = pending ?? isFullscreen(window)
    }

    /// A reopen (Dock click) shows the same window again, windowed, and nothing else re-states the
    /// claim: a close changes no mode, so `WindowFullscreenBridge`'s level is the same on the way
    /// back and it reports nothing. What the close recorded becomes owed here. The reconcile is
    /// ungated on purpose — it also carries out anything left unsatisfied for some other reason, a
    /// request made while the window was still hidden at launch as much as a close — and with nothing
    /// owed it does nothing, so a plain focus change can never toggle anything.
    @objc private func windowDidBecomeKey() {
        if let restoreOnReopen {
            pending = restoreOnReopen
            self.restoreOnReopen = nil
        }
        reconcile()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
