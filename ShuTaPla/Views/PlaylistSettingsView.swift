//
//  PlaylistSettingsView.swift
//  ShuTaPla
//
//  The per-playlist settings popover, raised from the center toolbar's Settings button. It
//  surfaces the overrides a playlist can set against the global defaults: each is a picker
//  whose first entry is "Default (…)", which clears the override (`nil`) so the playlist falls
//  back to the live global value. Slideshow and fit-mode edits route through the coordinator so
//  an active image channel reflects them immediately; the rest write straight to the model.
//

import SwiftUI

struct PlaylistSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    let playlist: Playlist

    var body: some View {
        let global = appState.globalSettings

        Form {
            switch playlist.mediaType {
            case .image: imageSettings(global)
            case .video, .audio: timelineSettings(global)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Image

    @ViewBuilder
    private func imageSettings(_ global: GlobalSettings) -> some View {
        Section("Slideshow") {
            Toggle("Slideshow", isOn: Binding(
                get: { playlist.preferences.slideshowEnabled },
                set: { coordinator.setSlideshowEnabled(playlist, $0) }
            ))
            Picker("Interval", selection: Binding(
                get: { playlist.preferences.slideshowInterval },
                set: { coordinator.setSlideshowInterval(playlist, $0) }
            )) {
                Text("Default (\(Int(global.defaultSlideshowInterval))s)").tag(TimeInterval?.none)
                ForEach(AppConstants.slideshowIntervals, id: \.self) { seconds in
                    Text("\(Int(seconds))s").tag(TimeInterval?.some(seconds))
                }
            }
        }

        Section("Display") {
            Picker("Fit mode", selection: Binding(
                get: { playlist.preferences.imageFitMode },
                set: { coordinator.setImageFitMode(playlist, $0) }
            )) {
                Text("Default (\(global.defaultImageFitMode.displayName))").tag(ImageFitMode?.none)
                ForEach(ImageFitMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(ImageFitMode?.some(mode))
                }
            }
        }
    }

    // MARK: - Video / audio

    @ViewBuilder
    private func timelineSettings(_ global: GlobalSettings) -> some View {
        @Bindable var playlist = playlist

        Section {
            Picker("Resume mid-file", selection: $playlist.preferences.filePositionPersistence) {
                Text("Default (\(global.defaultFilePositionPersistence ? "On" : "Off"))").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        } footer: {
            Text("When on, playback resumes where this playlist's files left off.")
        }
    }
}
