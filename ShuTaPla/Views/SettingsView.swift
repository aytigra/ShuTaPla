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
    @Environment(ThumbnailService.self) private var thumbnails

    /// Current cache size, loaded on appear and refreshed after each operation; `nil` while
    /// the first read is in flight.
    @State private var cacheSize: Int?
    /// The outcome of the last clear/sweep, shown beneath the buttons until the next one.
    @State private var lastResult: String?
    /// Guards the buttons while an operation runs, so a slow sweep can't be re-fired.
    @State private var isWorking = false

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
                    ForEach(ImageFitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section {
                LabeledContent("Cache size", value: cacheSize?.formattedFileSize ?? "—")
                HStack {
                    Button("Remove Orphans") { run { await removeOrphans() } }
                    Button("Clear All", role: .destructive) { run { await clearAll() } }
                }
                .disabled(isWorking)
                if let lastResult {
                    Text(lastResult).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Thumbnail cache")
            } footer: {
                Text("“Remove Orphans” deletes only thumbnails no playlist file references anymore.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // Runs each time the Settings panel appears. The scene keeps its `@State` across
        // close/reopen, so clear the previous run's message here rather than letting it linger,
        // and refresh the size in case the cache changed while the panel was closed.
        .task {
            lastResult = nil
            cacheSize = await thumbnails.cacheSize()
        }
    }

    /// Runs a cache operation with the buttons disabled, then refreshes the displayed size.
    private func run(_ operation: @escaping () async -> Void) {
        Task {
            isWorking = true
            await operation()
            cacheSize = await thumbnails.cacheSize()
            isWorking = false
        }
    }

    private func clearAll() async {
        await thumbnails.clearCache()
        lastResult = "Cache cleared."
    }

    private func removeOrphans() async {
        let result = await thumbnails.clearOrphans(liveFingerprints: appState.liveThumbnailFingerprints())
        let count = result.removed.pluralized(one: "1 thumbnail", many: "\(result.removed) thumbnails")
        lastResult = "Removed \(count) (\(result.bytes.formattedFileSize))."
    }
}
