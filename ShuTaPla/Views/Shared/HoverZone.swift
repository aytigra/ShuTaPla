//
//  HoverZone.swift
//  ShuTaPla
//
//  A thin edge strip that reports cursor enter/exit through an `NSTrackingArea`. We use
//  AppKit tracking rather than SwiftUI's `.onHover` because `.onHover` doesn't reliably
//  detect edge-of-screen hover in fullscreen, where the player lives. The parent sizes
//  and positions the strip along a window edge; this view only tracks the cursor over
//  whatever bounds it is given and fires the callbacks.
//
//  `.activeAlways` keeps tracking live in fullscreen and when the app isn't key;
//  `.inVisibleRect` makes the tracking rect follow the view's bounds automatically, so it
//  stays correct across resizes without rebuilding geometry by hand.
//

import SwiftUI
import AppKit

struct HoverZone: NSViewRepresentable {
    var onEnter: () -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onEnter = onEnter
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onEnter = onEnter
        nsView.onExit = onExit
    }

    @MainActor
    final class TrackingNSView: NSView {
        var onEnter: () -> Void = {}
        var onExit: () -> Void = {}

        private var hoverArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onEnter() }
        override func mouseExited(with event: NSEvent) { onExit() }
    }
}
