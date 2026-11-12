//
//  NoPlaylistsPlaceholder.swift
//  ShuTaPla
//
//  The placeholder a playlist list shows when none of its media types has a playlist yet, shared
//  by the Manager sidebar and the player-mode library selector. The nouns come off `MediaType`
//  beside its `displayName`; a list of several types names them all under a shared stack symbol.
//

import SwiftUI

struct NoPlaylistsPlaceholder: View {
    let mediaTypes: [MediaType]

    var title: String {
        "No \(alternatives(mediaTypes.map(\.displayName))) Playlists"
    }

    var message: String {
        "Add a folder of \(alternatives(mediaTypes.map(\.pluralNoun)))."
    }

    /// Joined in English to match the unlocalized sentence around it; `Locale.current` follows the
    /// system region format, which would put e.g. "или" inside English copy.
    private func alternatives(_ words: [String]) -> String {
        words.formatted(.list(type: .or).locale(Locale(identifier: "en")))
    }

    var systemImage: String {
        mediaTypes.count == 1 ? mediaTypes[0].systemImage : "rectangle.stack"
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
