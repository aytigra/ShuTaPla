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
                LabeledContent("Cache size") {
                    Text(cacheSize?.formattedFileSize ?? "—")
                        .foregroundStyle(AppConstants.cacheOverLimit(bytes: cacheSize) ? .orange : .primary)
                }
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
                Text("“Remove Orphans” deletes cached thumbnails no playlist file still references, plus any stray files.")
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
            await refreshSize()
        }
    }

    /// Runs a cache operation with the buttons disabled, then refreshes the size and pressure flag.
    private func run(_ operation: @escaping () async -> Void) {
        Task {
            isWorking = true
            await operation()
            await refreshSize()
            isWorking = false
        }
    }

    /// Re-reads the cache size for the readout and republishes the pressure flag, so both the
    /// Settings value and the Manager banner reflect the footprint after a clear/orphan sweep.
    private func refreshSize() async {
        let bytes = await thumbnails.cacheSize()
        cacheSize = bytes
        ThumbnailService.publishCachePressure(bytes: bytes)
    }

    private func clearAll() async {
        await thumbnails.clearCache()
        lastResult = "Cache cleared."
    }

    private func removeOrphans() async {
        let result = await thumbnails.clearOrphans(liveFingerprints: appState.liveThumbnailFingerprints())
        let count = result.removed.pluralized(one: "1 item", many: "\(result.removed) items")
        lastResult = "Removed \(count) (\(result.bytes.formattedFileSize))."
    }
}
