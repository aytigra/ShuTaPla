//
//  CGImage+HDR.swift
//  ShuTaPla
//
//  Whether a decoded image carries HDR range. The image engine decodes with
//  `kCGImageSourceDecodeToHDR`, so a genuinely HDR file comes back with a content headroom above
//  SDR (gain-map JPEGs) or a PQ/HLG colour space (natively encoded AVIFs); an SDR file reports a
//  headroom of 1.0 and a plain colour space. The image layer reads this to gate EDR opt-in.
//

import CoreGraphics

extension CGImage {

    /// True when the decoded image carries HDR range — a content headroom above SDR, or a PQ/HLG
    /// (`ITU-R 2100`) transfer function.
    var isHDR: Bool {
        if contentHeadroom > 1 { return true }
        guard let colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(colorSpace)
    }
}
