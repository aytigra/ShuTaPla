//
//  CursorAutoHider.swift
//  ShuTaPla
//
//  Hides the mouse cursor during uninterrupted playback and brings it back the
//  moment the cursor moves. While `isActive`, a movement resets an idle timer; when
//  the timer fires the cursor is hidden until the next move (`setHiddenUntilMouseMoves`,
//  which the system reverses automatically on movement). Turning `isActive` off — an
//  overlay opening, a pause, leaving Player mode — cancels the timer and restores the
//  cursor at once. A full-bleed tracking area sees the movement regardless of the
//  overlays stacked above it.
//

import SwiftUI
import AppKit

struct CursorAutoHider: NSViewRepresentable {
    /// Whether auto-hide is armed: the player is actively playing with nothing to
    /// interact with on screen.
    var isActive: Bool

    /// Idle time before the cursor is hidden.
    var idleDelay: TimeInterval = 2.5

    func makeNSView(context: Context) -> CursorTrackingView {
        let view = CursorTrackingView()
        view.idleDelay = idleDelay
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: CursorTrackingView, context: Context) {
        nsView.idleDelay = idleDelay
        nsView.isActive = isActive
    }

    static func dismantleNSView(_ nsView: CursorTrackingView, coordinator: ()) {
        nsView.isActive = false
    }

    @MainActor
    final class CursorTrackingView: TrackingAreaView {
        var idleDelay: TimeInterval = 2.5

        var isActive = false {
            didSet {
                guard isActive != oldValue else { return }
                isActive ? scheduleHide() : reveal()
            }
        }

        private var hideWork: DispatchWorkItem?

        override var trackingEventOptions: NSTrackingArea.Options { [.mouseMoved] }

        override func mouseMoved(with event: NSEvent) {
            guard isActive else { return }
            scheduleHide()   // movement already reveals the cursor; re-arm the idle hide
        }

        /// Cancels any pending hide and shows the cursor immediately.
        private func reveal() {
            hideWork?.cancel()
            hideWork = nil
            NSCursor.setHiddenUntilMouseMoves(false)
        }

        /// (Re)starts the idle countdown after which the cursor is hidden until moved.
        private func scheduleHide() {
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive else { return }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: work)
        }
    }
}
