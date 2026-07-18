//
//  PlaylistSettingsView.swift
//  ShuTaPla
//
//  The per-playlist settings popover, raised from the center toolbar's Settings button. Most
//  controls are overrides against the global defaults: a picker whose first entry is "Default (…)"
//  clears the override (`nil`) so the playlist falls back to the live global value. The gallery
//  tile-width slider is a standalone per-playlist preference with no global default. Slideshow and
//  fit-mode edits route through the coordinator so an active image channel reflects them
//  immediately; the rest write straight to the model.
//

import SwiftUI

struct PlaylistSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist

    var body: some View {
        let global = appState.globalSettings

        Form {
            switch playlist.mediaType {
            case .image: imageSettings(global)
            case .video, .audio: timelineSettings(global)
            }
            if playlist.mediaType != .audio {
                gallerySettings()
                duplicatesSection()
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Find duplicates

    /// Runs the find-duplicates tool: the Manager center regroups its files by content so
    /// duplicates sit together, until a filter interaction or playlist switch returns it. Only
    /// files with a generated thumbnail carry the content fingerprint it compares.
    @ViewBuilder
    private func duplicatesSection() -> some View {
        Section {
            Button("Find Duplicates") {
                appState.findDuplicates(in: playlist)
                dismiss()
            }
        } footer: {
            Text("Groups files with identical content in the center list. Compares only files that have a generated thumbnail.")
        }
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

    // MARK: - Gallery (image + video)

    /// Sets the gallery's adaptive minimum tile width; the maximum tracks it by
    /// `GalleryGrid.galleryMaxRatio`. The value shown is what the grid actually uses —
    /// the default until the playlist chooses its own. Manager-only, so it writes straight to the
    /// model with no coordinator involvement.
    @ViewBuilder
    private func gallerySettings() -> some View {
        let width = GalleryGrid.gridMetrics(min: playlist.preferences.galleryMinItemWidth).min

        Section("Gallery") {
            LabeledContent("Tile width") {
                Slider(
                    value: Binding(
                        get: { Double(width) },
                        set: { playlist.preferences.galleryMinItemWidth = $0 }
                    ),
                    in: 100...600,
                    step: 20
                )
                Text("\(Int(width)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
