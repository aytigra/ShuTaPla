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
    /// running. Reopening the window calls `windowWillReopen`. The `RootView` window bridge also
    /// calls it while the window tears down on quit: the halt and persist are idempotent there, and
    /// `applicationWillTerminate` persists and saves on that path anyway.
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

    /// A quit request (`applicationShouldTerminate`). A quit during disk work (`hasDiskWork`) is
    /// held: a strip or a cross-volume move cut short leaves a hidden sidecar or a partial copy that
    /// no re-scan heals, and the final save of a playlist delete cut short keeps part of its files
    /// deleted. The quit is held, so a logout, restart or shutdown continues when the work ends
    /// (`quitAfterWait`); the system gives it 2 minutes. A force quit is not guarded.
    ///
    /// The wait holds only for a quit that AppKit routes through `applicationShouldTerminate`: the
    /// quit key, the *Quit* menu item and a quit Apple event. Never call `NSApp.terminate` from app
    /// code. From a timer it skips the delegate and quits at once. From a main-queue block it runs
    /// the wait's nested run loop inside that block, so the main queue (and `quitAfterWait`'s Task)
    /// can't run and the wait never ends.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard hasDiskWork else { return .terminateNow }
        isWaitingToQuit = true
        return .terminateLater
    }

    /// Whether files are busy or a playlist delete runs: the work a quit waits for.
    var hasDiskWork: Bool {
        busyFileIDs.isNotEmpty || playlistWork.isDeletingAny
    }

    /// *Cancel Quitting* in the wait alert: the app stays open, and a held logout stops.
    func cancelQuit() {
        endQuitWait(quitting: false)
    }

    /// Runs on each change of the disk work. When a quit waits and the work has ended, quits on the
    /// next main-actor turn, so the op that ended it finishes its synchronous tail (a persist)
    /// first. A *Cancel Quitting* in between keeps the app open, and work that starts in between
    /// holds the quit until it ends. The quit does not wait for a report raised during the wait:
    /// holding it for the report's *OK* would stop an unattended logout or shutdown. The report
    /// queues ahead of the wait alert, which hides *Cancel Quitting* until its *OK*, and the app
    /// quits once the work ends, dismissed or not. Each file op fails with no change to the file,
    /// so a file it could not change stays in its playlist.
    func quitAfterWait() {
        guard isWaitingToQuit, !hasDiskWork else { return }
        Task {
            guard !hasDiskWork else { return }
            endQuitWait(quitting: true)
        }
    }

    /// Answers the held quit once: the alert's dismissal and a second release can both reach here.
    private func endQuitWait(quitting: Bool) {
        guard isWaitingToQuit else { return }
        isWaitingToQuit = false
        replyToTerminate(quitting)
    }

    /// The quit-wait alert's lines: the first busy file names in Finder order, a count of the rest, and a
    /// line for a playlist delete in progress.
    var quitWaitItems: [String] {
        let shown = 5
        let (names, count) = modelContext.fileNames(withIDs: Array(busyFileIDs), limit: shown)
        var items = names
        let rest = count - shown
        if rest > 0 { items.append(rest.pluralized(one: "1 more file", many: "\(rest) more files")) }
        if playlistWork.isDeletingAny { items.append("A playlist delete") }
        return items
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
