//
//  View+MetadataCaption.swift
//  ShuTaPla
//
//  The one look a numeric metadata value wears wherever it is shown — a file's size, its pixel
//  dimensions, a running time, the gallery's tile-width readout. Monospaced digits so a value that
//  changes in place doesn't shuffle the glyphs beside it (a ticking timecode) and so a column of
//  values aligns digit-for-digit; caption on secondary so the numbers stay subordinate to the name
//  they annotate.
//

import SwiftUI

extension View {
    /// Styles a numeric metadata value: caption-sized monospaced digits, secondary.
    func metadataCaption() -> some View {
        font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
