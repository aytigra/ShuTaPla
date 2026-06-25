//
//  FullscreenView.swift
//  ShuTaPla
//
//  A zero-size bridge that asks the hosting window to be fullscreen while it is in
//  the view tree and windowed when it leaves — the mechanism the window has no
//  SwiftUI equivalent for. Player mode mounts it; returning to Manager unmounts it.
//  It only expresses the desired state; the window's `FullscreenController` owns the
//  animated transition and reconciles rapid enter/exit without flicker or stale state.
//
//  The request is made off the window-attachment callback (and on a fresh run-loop
//  turn), never during the layout pass, so it never resizes the hosting window while
//  SwiftUI is mid-render (which AppKit reports as a reentrant layout).
//

import SwiftUI
import AppKit

struct FullscreenView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowFullscreenView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? WindowFullscreenView)?.requestExit()
    }

    /// A zero-size view that asks its window to go fullscreen once attached and back to windowed
    /// when torn down.
    @MainActor
    private final class WindowFullscreenView: NSView {
        /// The window we asked to go fullscreen, captured at attach. `dismantleNSView` runs after
        /// the view has detached (`self.window` is already `nil`), so the exit request reads this.
        private weak var hostWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            hostWindow = window
            // Hop off the current layout/render pass before changing window geometry.
            DispatchQueue.main.async { [weak self] in
                self?.hostWindow?.fullscreenController.setDesired(true)
            }
        }

        /// Asks the window back to windowed. Called from `dismantleNSView` during SwiftUI teardown,
        /// so the request runs on a fresh run-loop turn (not inside that layout/render pass), with
        /// the window captured strongly so it still fires after the view is gone.
        func requestExit() {
            guard let window = hostWindow else { return }
            DispatchQueue.main.async { window.fullscreenController.setDesired(false) }
        }
    }
}
