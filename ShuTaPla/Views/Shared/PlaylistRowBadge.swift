//
//  PlaylistRowBadge.swift
//  ShuTaPla
//
//  The trailing accessory of a playlist row, shared by the Manager sidebar and the player-mode
//  library selector: a spinner while the playlist is being deleted or re-scanned, its file count
//  otherwise.
//
//  It is a view of its own so the count has its own invalidation boundary, and the boundary is the
//  point: `Playlist.fileCount` is a `fetchCount` and registers no Observation dependency, so it is
//  gated on `playlistsVersion` through `AppState.fileCount(of:)` — and that gate has to be read
//  *here*. A bump does re-evaluate the enclosing list body, but the body hands `ForEach` the same
//  `Playlist` references and an unchanged closure, so SwiftUI keeps the rows it already has and a
//  gate read up there never reaches the badge. This leaf registers against the version itself, so a
//  bump re-reads the count while the row around it stays put.
//

import SwiftUI

struct PlaylistRowBadge: View {
    let playlist: Playlist

    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.deletingPlaylistIDs.contains(playlist.id) {
            ProgressView()
                .controlSize(.small)
                .tint(.red)
        } else if appState.busyPlaylistIDs.contains(playlist.id) {
            ProgressView()
                .controlSize(.small)
        } else {
            Text("\(appState.fileCount(of: playlist))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
