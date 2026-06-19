//
//  TrackingAreaView.swift
//  ShuTaPla
//
//  Base for the AppKit views that watch the cursor over their bounds (the edge hover
//  strips and the playback cursor auto-hider).
//

import AppKit

/// An `NSView` that keeps a single full-bounds `NSTrackingArea`, rebuilt on
/// `updateTrackingAreas` so it follows the view's size. Subclasses declare which mouse
/// events they want and override the matching `mouse*` handlers.
///
/// `.activeAlways` keeps tracking live in fullscreen and when the app isn't key (where
/// the player runs); `.inVisibleRect` makes the rect follow the bounds automatically, so
/// it stays correct across resizes without rebuilding geometry by hand.
@MainActor
class TrackingAreaView: NSView {
    /// The mouse events the tracking area should report. Combined with the always-on
    /// `.activeAlways` and `.inVisibleRect` options.
    var trackingEventOptions: NSTrackingArea.Options { [] }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: trackingEventOptions.union([.activeAlways, .inVisibleRect]),
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }
}
