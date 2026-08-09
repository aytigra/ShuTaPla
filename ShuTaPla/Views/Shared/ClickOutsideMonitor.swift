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
    /// How far above the panel still counts as inside — the height of the control it hangs from.
    /// Without it the monitor closes the panel on the mouse-down that the control's own action then
    /// toggles back open, and the control stops working.
    var anchorHeight: CGFloat = 0
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

        /// The panel's own bounds grown upwards over its anchor — AppKit's y runs up, so a taller
        /// rect from the same origin is exactly that.
        private func isInside(_ event: NSEvent, of view: NSView) -> Bool {
            let bounds = view.bounds
            let inside = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height + parent.anchorHeight
            )
            return inside.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}
