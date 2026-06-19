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
    final class TrackingNSView: TrackingAreaView {
        var onEnter: () -> Void = {}
        var onExit: () -> Void = {}

        override var trackingEventOptions: NSTrackingArea.Options { [.mouseEnteredAndExited] }

        override func mouseEntered(with event: NSEvent) { onEnter() }
        override func mouseExited(with event: NSEvent) { onExit() }
    }
}
