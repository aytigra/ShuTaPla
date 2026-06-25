//
//  SettingsView.swift
//  ShuTaPla
//
//  Global defaults, opened with Cmd+, via the `Settings` scene. Edits write straight to the
//  shared `GlobalSettings` singleton, so a change takes effect immediately — the coordinator
//  reads it live, and new playlists (whose per-playlist overrides are unset) inherit it.
//  Each playlist can override any of these in its own settings popover (`PlaylistSettingsView`).
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.globalSettings

        Form {
            Section {
                Picker("Slideshow interval", selection: $settings.defaultSlideshowInterval) {
                    ForEach(AppConstants.slideshowIntervals, id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                Toggle("Resume playback mid-file", isOn: $settings.defaultFilePositionPersistence)
            } header: {
                Text("Playback")
            } footer: {
                Text("New playlists inherit these defaults. Any playlist can override them in its own settings.")
            }

            Section("Images") {
                Picker("Image fit mode", selection: $settings.defaultImageFitMode) {
                    Text("Fit").tag(ImageFitMode.fit)
                    Text("Cover").tag(ImageFitMode.cover)
                    Text("Original").tag(ImageFitMode.original)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
