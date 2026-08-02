//
//  NoPlaylistsPlaceholder.swift
//  ShuTaPla
//
//  The placeholder a playlist list shows when its media type has none yet, shared by the Manager
//  sidebar and the player-mode library selector. Both list one type at a time, so the symbol and
//  the noun come off `MediaType` beside its `displayName`.
//

import SwiftUI

struct NoPlaylistsPlaceholder: View {
    let mediaType: MediaType

    var body: some View {
        ContentUnavailableView {
            Label("No \(mediaType.displayName) Playlists", systemImage: mediaType.systemImage)
        } description: {
            Text("Add a folder of \(mediaType.pluralNoun).")
        }
    }
}
