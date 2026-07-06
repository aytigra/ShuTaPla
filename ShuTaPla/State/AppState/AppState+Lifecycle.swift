//
//  AppState+Lifecycle.swift
//  ShuTaPla
//
//  The window-close / reopen / terminate hooks the `AppDelegate` calls, and the persisted
//  window frame. Closing the window (not quitting) halts playback through suppression and keeps
//  the app running; reopening lifts it. Launch resume is handled in `init` via `reconstructPlayback`.
//

import Foundation
import SwiftData
import AppKit

extension AppState {

    /// Window close (not quit): write a resume point and activate suppression, leaving each
    /// playlist's own Stopped/Playing/Paused state untouched. The window hides; the app keeps
    /// running. Reopening the window calls `windowWillReopen`.
    func windowWasClosed() {
        coordinator.persistLivePositions()
        coordinator.suppress()
    }

    /// Dock reopen of the hidden window: lift the close-time suppression so Playing playlists
    /// continue and Paused stay paused.
    func windowWillReopen() {
        coordinator.unsuppress()
        refreshCachePressureOnWindowOpen()
    }

    /// Measures the on-disk thumbnail cache (off the main actor) and writes the cache-pressure flag
    /// the Manager notice-strip banner reads. Runs on a window-open — cold launch and Dock reopen
    /// alike — not on every playlist scan: while the window is closed the footprint only moves if
    /// another process touched the cache, so re-measuring the whole directory once per open suffices
    /// and keeps the frequent scan path clear of a directory enumeration.
    func refreshCachePressureOnWindowOpen() {
        Task { ThumbnailService.publishCachePressure(bytes: await ThumbnailService.defaultCacheSize()) }
    }

    /// App termination: a final write of both channels' live positions, then a synchronous save
    /// so the resume points survive the teardown (autosave may not flush in time).
    func applicationWillTerminate() {
        coordinator.persistLivePositions()
        try? modelContext.save()
    }

    /// The window's last frame, restored when the window attaches at launch so it reopens at the
    /// same size and position. `nil` on first launch (nothing persisted) or if the stored data
    /// can't be decoded — the window then keeps its default frame. `NSRect` is `Codable`.
    var restoredWindowFrame: NSRect? {
        guard let data = appStateModel.windowFrame else { return nil }
        return try? JSONDecoder().decode(NSRect.self, from: data)
    }

    /// Records the window's frame, called debounced on every move/resize by `WindowFrameBridge`.
    /// The encoded frame rides the model's autosave; `applicationWillTerminate`'s save flushes
    /// the last one at quit.
    func persistWindowFrame(_ frame: NSRect) {
        appStateModel.windowFrame = try? JSONEncoder().encode(frame)
    }
}
