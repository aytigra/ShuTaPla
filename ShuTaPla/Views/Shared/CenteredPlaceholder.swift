//
//  CenteredPlaceholder.swift
//  ShuTaPla
//
//  The empty states this app draws by hand rather than with `ContentUnavailableView`, which sizes
//  itself against the window and so drifts to screen centre instead of centring in the column or
//  the sliding overlay that hosts it. Both are the same figure — a glyph over a line of text,
//  centred in whatever space the caller gives it — and differ only in where they sit:
//  `CenteredPlaceholder` fills a panel column as secondary chrome, `StagePlaceholder` covers the
//  black player stage in white and can carry a spinner for a wait that will end on its own.
//

import SwiftUI

/// A glyph-and-title empty state, centred in the panel column that hosts it.
struct CenteredPlaceholder: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
            Text(title)
                .font(.title3.weight(.semibold))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A glyph-and-title state over the opaque player stage, standing in for the frame that isn't
/// there. The caller frames it (the Player covers the window, the Manager preview its card) and
/// owns any transition, since only the caller knows what it is replacing.
struct StagePlaceholder: View {
    let title: String
    let systemImage: String
    /// A spinner under the title, for a state that resolves on its own — a download in flight.
    let showsProgress: Bool

    init(_ title: String, systemImage: String, showsProgress: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.showsProgress = showsProgress
    }

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                // One line always: the title is a filename as often as a sentence, and a long name
                // elides in the middle so its extension survives.
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding()
        }
    }
}
