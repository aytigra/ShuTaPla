//
//  WindowCloseBridge.swift
//  ShuTaPla
//
//  A zero-size bridge that reports when its hosting window closes. Mounted on the
//  main content view, it scopes the observation to that window — the auxiliary
//  Settings window is a separate Scene and never triggers it. Closing the window
//  keeps the app running (the window hides, playback is halted), which is the case
//  this exists for. The same notification also fires while the window tears down on
//  quit; the halt-and-persist it triggers is idempotent and harmless there, since
//  `applicationWillTerminate` persists and saves on that path anyway.
//

import SwiftUI
import AppKit

struct WindowCloseBridge: NSViewRepresentable {
    /// Called when the hosting window is about to close — a deliberate close, or the window
    /// tearing down on quit.
    let onClose: () -> Void

    func makeNSView(context: Context) -> CloseObservingView {
        let view = CloseObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: CloseObservingView, context: Context) {
        nsView.onClose = onClose
    }

    /// A zero-size view that observes `willCloseNotification` for the one window it attaches to.
    @MainActor
    final class CloseObservingView: NSView {
        var onClose: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification, object: window
            )
        }

        @objc private func windowWillClose() { onClose() }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
