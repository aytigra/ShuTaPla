//
//  FullscreenView.swift
//  ShuTaPla
//
//  A zero-size bridge that drives the hosting window into fullscreen while it is
//  in the view tree and back out when it leaves — the mechanism the window has no
//  SwiftUI equivalent for. Player mode mounts it; returning to Manager unmounts
//  it, which exits fullscreen. (Animated, polished transitions are Task 18.)
//
//  The toggle is driven off the window-attachment callback rather than the layout
//  pass, and always on a fresh run-loop turn, so it never resizes the hosting
//  window while SwiftUI is mid-render (which AppKit reports as a reentrant layout).
//

import SwiftUI
import AppKit

struct FullscreenView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowFullscreenView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? WindowFullscreenView)?.scheduleExit()
    }

    /// A zero-size view that enters fullscreen once it is attached to a window and
    /// exits when it is torn down.
    @MainActor
    private final class WindowFullscreenView: NSView {
        private var didEnter = false

        /// The window we drove into fullscreen, captured at entry. `dismantleNSView` runs after
        /// the view has detached (`self.window` is already `nil`), so the exit toggle reads this.
        private weak var hostWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            hostWindow = window
            // Hop off the current layout/render pass before changing window geometry.
            DispatchQueue.main.async { [weak self] in self?.enterFullscreen() }
        }

        private func enterFullscreen() {
            guard !didEnter, let window = hostWindow, !window.styleMask.contains(.fullScreen) else { return }
            didEnter = true
            window.toggleFullScreen(nil)
        }

        /// Schedules the fullscreen exit off the current run-loop turn. Called from
        /// `dismantleNSView` during SwiftUI teardown, so the toggle must not run inside that
        /// layout/render pass (AppKit reports that as a reentrant layout).
        func scheduleExit() {
            guard let window = hostWindow, window.styleMask.contains(.fullScreen) else { return }
            // Strongly capture the window (it outlives the view) so the deferred exit still runs
            // after teardown; `nonisolated(unsafe)` only because `NSWindow` isn't `Sendable`.
            nonisolated(unsafe) let target = window
            DispatchQueue.main.async {
                if target.styleMask.contains(.fullScreen) { target.toggleFullScreen(nil) }
            }
        }
    }
}
