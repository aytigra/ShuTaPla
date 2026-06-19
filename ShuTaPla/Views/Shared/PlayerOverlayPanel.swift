//
//  PlayerOverlayPanel.swift
//  ShuTaPla
//
//  The shared chrome of the Player-mode overlays (the Playlists panel, the Files &
//  Tags panel, and the floating control bar).
//

import SwiftUI

extension View {
    /// A solid translucent dark fill with light controls/text forced on top. The fill
    /// is deliberately not a live blur, so animating an overlay in and out over video
    /// stays cheap to composite and never stalls the video's redraw on the main thread.
    /// `cornerRadius` rounds (and the caller clips) the fill — the floating control bar
    /// passes one; the full-bleed side and bottom panels leave it square.
    func playerOverlayPanel(opacity: Double = 0.92, cornerRadius: CGFloat = 0) -> some View {
        background(Color.black.opacity(opacity), in: RoundedRectangle(cornerRadius: cornerRadius))
            .environment(\.colorScheme, .dark)
    }
}
