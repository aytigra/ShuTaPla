//
//  TransportButton.swift
//  ShuTaPla
//
//  The icon button every player control surface is built from — the bottom playback bar, the
//  Manager sidebar's audio inlet, and the audio overlay's chrome. One type so a control reads
//  the same wherever it sits: `ControlButtonStyle`'s hover fill, an accent tint while its
//  state is on, and a single title serving as both tooltip and accessibility label, so the two
//  can't drift.
//

import SwiftUI

struct TransportButton: View {
    /// How much room the glyph is given. The player surfaces pin theirs to a fixed cell so a
    /// symbol swap (play↔pause) can't shift the row around it; the inlet sits in a text row and
    /// takes the ambient font, sized by the glyph itself. Pure metrics, so `nonisolated` — they
    /// are the layout's test seam.
    nonisolated enum Size {
        /// The sidebar inlet: ambient font, no cell.
        case inline
        /// The bottom playback bar: a large glyph in the shared cell.
        case bar
        /// Overlay chrome: a smaller, heavier glyph in the same cell.
        case chrome

        var font: Font? {
            switch self {
            case .inline: nil
            case .bar: .title3
            case .chrome: .callout.weight(.semibold)
            }
        }

        /// The cell the glyph is centred in, or `nil` to let it size itself.
        var glyphFrame: CGSize? {
            switch self {
            case .inline: nil
            case .bar, .chrome: CGSize(width: 26, height: 22)
            }
        }
    }

    let title: String
    let systemImage: String
    var isActive = false
    var size: Size = .inline
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(size.font)
                // Inactive keeps the ambient foreground rather than pinning `.primary`, so a
                // dimmed context still reads through the button.
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.foreground))
                .frame(width: size.glyphFrame?.width, height: size.glyphFrame?.height)
        }
        .buttonStyle(ControlButtonStyle())
        .help(title)
    }
}
