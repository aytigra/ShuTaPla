//
//  CGSize+Dimensions.swift
//  ShuTaPla
//
//  Pixel-dimensions formatting for the Manager's file-list/gallery size indicators.
//

import CoreGraphics

extension CGSize {
    /// Pixel dimensions as `"1920×1080"` — width and height joined by a true multiplication
    /// sign (`×`, not the letter `x`). Fractional parts are truncated; media pixel sizes are
    /// whole numbers.
    var dimensionsText: String {
        "\(Int(width))×\(Int(height))"
    }
}
