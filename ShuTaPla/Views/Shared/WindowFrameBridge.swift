//
//  WindowFrameBridge.swift
//  ShuTaPla
//
//  A zero-size bridge that ties the hosting window's frame to persisted state.
//  It restores the saved frame once, the first time it attaches to a window, so the
//  window reopens where it was — but only if that frame still overlaps a screen
//  (a frame saved on a since-removed display is left for the default position rather
//  than stranding the window off-screen). Thereafter it reports every move/resize
//  (debounced) so the latest geometry is written back. Scoped to the one window it
//  attaches to — the auxiliary Settings window is a separate Scene and never participates.
//

import SwiftUI
import AppKit

struct WindowFrameBridge: NSViewRepresentable {
    /// The frame to restore when the window first attaches, or `nil` to leave the default.
    let restoredFrame: () -> NSRect?
    /// Called with the window's frame after it settles from a move or resize.
    let onFrameChange: (NSRect) -> Void

    func makeNSView(context: Context) -> FrameObservingView {
        let view = FrameObservingView()
        view.restoredFrame = restoredFrame
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: FrameObservingView, context: Context) {
        nsView.restoredFrame = restoredFrame
        nsView.onFrameChange = onFrameChange
    }

    /// A zero-size view that restores its window's frame on attach and observes
    /// `didMove` / `didResize` for the one window it attaches to.
    @MainActor
    final class FrameObservingView: NSView {
        var restoredFrame: () -> NSRect? = { nil }
        var onFrameChange: (NSRect) -> Void = { _ in }

        /// The pending debounced write, cancelled and rescheduled on each move/resize so a drag
        /// persists once it settles rather than on every intermediate frame.
        private var pendingPersist: DispatchWorkItem?

        /// The saved frame is restored once, on the first attach. A later re-attach must not snap
        /// the window back to the last-persisted frame on top of the user's live position.
        private var didRestore = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
            center.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            guard window != nil else { return }

            // Hop off the current layout pass before touching window geometry: `viewDidMoveToWindow`
            // can run mid-layout, and `setFrame(display:)` would re-enter it. Restoring *before*
            // registering the observers also keeps that programmatic resize from being persisted
            // back as a "change".
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !self.didRestore {
                    self.didRestore = true
                    // Skip a frame that no longer overlaps any screen (display layout changed since
                    // it was saved); restoring it would put the window where it can't be reached.
                    if let frame = self.restoredFrame(),
                       frame.isReachable(onAnyOf: NSScreen.screens.map(\.visibleFrame)) {
                        window.setFrame(frame, display: true)
                    }
                }
                center.addObserver(self, selector: #selector(self.windowGeometryChanged),
                                   name: NSWindow.didMoveNotification, object: window)
                center.addObserver(self, selector: #selector(self.windowGeometryChanged),
                                   name: NSWindow.didResizeNotification, object: window)
            }
        }

        @objc private func windowGeometryChanged() {
            guard let window else { return }
            pendingPersist?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onFrameChange(window.frame) }
            pendingPersist = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        // A debounced write outstanding at teardown is harmless — it captures `self` weakly,
        // so it no-ops once the view is gone.
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
