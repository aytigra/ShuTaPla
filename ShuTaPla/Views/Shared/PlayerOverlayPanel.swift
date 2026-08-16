//
//  PlayerOverlayPanel.swift
//  ShuTaPla
//
//  The shared chrome of the Player-mode overlays (the Playlists panel, the Files &
//  Tags panel, and the floating control bar).
//

import SwiftUI

extension View {
    /// A solid dark fill with light controls/text forced on top. The fill is deliberately
    /// not a live blur, so animating an overlay in and out over video stays cheap to
    /// composite and never stalls the video's redraw on the main thread. It is opaque
    /// unless a caller asks to see the picture through it — the floating control bar and
    /// the compact audio bar do, being thin strips laid over what is playing.
    /// `cornerRadius` rounds (and the caller clips) the fill — the floating control bar
    /// passes one; the full-bleed side and bottom panels leave it square.
    func playerOverlayPanel(opacity: Double = 1, cornerRadius: CGFloat = 0) -> some View {
        background(Color.black.opacity(opacity), in: RoundedRectangle(cornerRadius: cornerRadius))
            .environment(\.colorScheme, .dark)
    }
}
