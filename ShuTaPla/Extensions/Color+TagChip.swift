//
//  Color+TagChip.swift
//  ShuTaPla
//
//  The tint a tag chip's capsule is filled at. The filter strip's chips and the saved search's
//  summary chips are drawn by their own views — one carries a remove button and a selection, the
//  other is text in a sentence — and this is the one value that has to agree for the two to read as
//  the same pill, so it is stated here rather than in each.
//

import SwiftUI

extension Color {
    /// This color as a tag chip's fill. `selected` deepens it for the chip the caret sits on, which
    /// only the editable chips have.
    func tagChipFill(selected: Bool = false) -> Color {
        opacity(selected ? 0.4 : 0.18)
    }
}
