//
//  NSScreen+EDR.swift
//  ShuTaPla
//
//  Whether a display can present extended dynamic range. Both HDR output paths gate on this: the
//  image layer opts the backing layer into EDR (`EDRImageLayer`), and the video engine tells mpv
//  the layer is EDR-capable so it doesn't tone-map HDR down to SDR (`VideoPlaybackEngine`).
//

import AppKit

extension NSScreen {

    /// Whether this display can present extended dynamic range — its HDR headroom exceeds SDR.
    /// An SDR display reports a maximum potential component value of 1.0.
    var supportsEDR: Bool { maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
}
