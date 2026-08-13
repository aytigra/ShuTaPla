//
//  ClickOutsideMonitor.swift
//  ShuTaPla
//
//  Reports a mouse-down that lands outside the view it backs — the two things macOS gives no
//  SwiftUI answer for: dismissing a panel drawn inside the window (an overlay, not a popover with a
//  window of its own), and resigning a text field, since AppKit hands its field editor over only to
//  another responder and never to a plain click on scenery. A local monitor reports the click
//  without consuming it, so the same click both acts here and reaches whatever it hit.
//
//  Everything is measured in the backing view's own AppKit coordinates, so no SwiftUI-global frames
//  have to be tracked and kept in step.
//

import SwiftUI
import AppKit

struct ClickOutsideMonitor: NSViewRepresentable {
    /// How far above the backing view still counts as inside — the control it hangs from. Without
    /// it the monitor dismisses on the mouse-down that the control's own action then toggles back
    /// open, and the control stops working.
    var above: CGFloat = 0
    /// How far below the backing view still counts as inside — the panel it floats over. The
    /// counterpart to `above` for a control that opens *downwards*, whose panel is drawn as an
    /// overlay and so is nowhere in the backing view's own bounds.
    var below: CGFloat = 0
    let onOutside: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: ClickOutsideMonitor
        private var monitor: Any?

        init(_ parent: ClickOutsideMonitor) { self.parent = parent }

        func start(on view: NSView) {
            // Right-click too: a context menu raised on a file row is as much a click elsewhere.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self, weak view] event in
                guard let self, let view, event.window === view.window else { return event }
                if !self.isInside(event, of: view) { self.parent.onOutside() }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func isInside(_ event: NSEvent, of view: NSView) -> Bool {
            ClickOutsideMonitor.insideRect(view.bounds, above: parent.above, below: parent.below)
                .contains(view.convert(event.locationInWindow, from: nil))
        }
    }

    /// The view's own bounds grown over the regions that belong to it but lie outside its layout.
    /// AppKit's y runs up, so `above` is height added at the top and `below` is a lowered origin.
    ///
    /// Geometry only, off the actor the representable is bound to, so it can be exercised directly.
    nonisolated static func insideRect(_ bounds: CGRect, above: CGFloat, below: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: bounds.minY - below,
            width: bounds.width,
            height: bounds.height + above + below
        )
    }
}
