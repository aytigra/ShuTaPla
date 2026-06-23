//
//  WelcomeView.swift
//  ShuTaPla
//
//  First-run screen shown when no playlists exist. A prominent "Add Playlist"
//  button raises the shared `AddPlaylistFlow`: a folder picker whose chosen folder
//  is scanned into a playlist, prompting for a media type when the folder is Mixed.
//

import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("Welcome to ShuTaPla")
                    .font(.largeTitle.weight(.semibold))
                Text("Add a folder of videos, images, or audio to get started.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                appState.isImportingPlaylist = true
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isAddingPlaylist)

            if appState.isAddingPlaylist {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
