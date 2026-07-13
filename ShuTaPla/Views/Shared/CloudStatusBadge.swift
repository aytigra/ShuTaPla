//
//  CloudStatusBadge.swift
//  ShuTaPla
//
//  The small iCloud-availability indicator shown alongside a file's on-disk size, in the
//  Manager list and gallery and in the audio transport. The glyph itself is a pure readout; the
//  Manager list and gallery wrap it in a `Button` that requests the file's download, while the
//  audio transport shows it plainly.
//  `.inCloud` and `.downloading` each carry a semantic SF Symbol and a VoiceOver label;
//  `.local` renders nothing. The glyph/label mapping lives on `CloudStatus` as a pure,
//  `nonisolated` core so it's exercised without a view, and so the gallery — which wraps the
//  same glyph in its own dark pill — reads it directly rather than duplicating the literals.
//

import SwiftUI

nonisolated extension CloudStatus {

    /// The SF Symbol for this status, or `nil` when the file is fully local and needs no badge.
    var badgeSymbol: String? {
        switch self {
        case .local: nil
        case .inCloud: "icloud"
        case .downloading: "icloud.and.arrow.down"
        }
    }

    /// A VoiceOver description of the status, or `nil` when there is nothing to announce.
    var badgeAccessibilityLabel: String? {
        switch self {
        case .local: nil
        case .inCloud: "In iCloud, not downloaded"
        case .downloading: "Downloading from iCloud"
        }
    }
}

/// Renders the current status' glyph with its accessibility label, or nothing when local.
/// Callers supply the surrounding styling (secondary caption in the list and audio transport;
/// the gallery wraps its glyph in a pill directly via `CloudStatus.badgeSymbol`).
struct CloudStatusBadge: View {
    let status: CloudStatus

    var body: some View {
        if let symbol = status.badgeSymbol {
            Image(systemName: symbol)
                .accessibilityLabel(status.badgeAccessibilityLabel ?? "")
        }
    }
}
