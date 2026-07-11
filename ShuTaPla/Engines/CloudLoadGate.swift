//
//  CloudLoadGate.swift
//  ShuTaPla
//
//  Defers a playback engine's load of an evicted (not-yet-local) file until its bytes
//  arrive. On a load the engine hands the gate the file and the actual byte-load as a
//  closure: a `.local` file loads at once; an evicted one is held pending, its download
//  is requested, and the load runs later when the live cloud feed flips the file to
//  `.local`. Shared by the mpv and image engines so all three channels wait the same way.
//  The pending file is observable, so the player views overlay a downloading placeholder
//  while it is set.
//

import Foundation
import Observation

@MainActor
@Observable
final class CloudLoadGate {

    /// The evicted file being awaited, or `nil` when nothing is pending. The engines expose
    /// this to their player views, which show the downloading placeholder while it is set.
    private(set) var pendingFile: PlaylistFile?

    /// The deferred byte-load for `pendingFile`, run once its bytes arrive. Held here (rather than
    /// captured in the observation) so the `@Sendable` change hook captures only `self`.
    private var pendingPerform: (() -> Void)?

    /// Loads `file` now if it is already `.local`; otherwise holds it pending, asks
    /// `requestDownload` to pull it from iCloud, and runs `perform` later when the live feed
    /// flips the file to `.local`. A `nil` file or a `.local` one clears any prior pending wait.
    /// `perform` should capture the engine weakly — the gate holds it until the file arrives.
    func load(
        _ file: PlaylistFile?,
        perform: @escaping () -> Void,
        requestDownload: (PlaylistFile) -> Void
    ) {
        guard let file, file.cloudStatus != .local else {
            clear()
            perform()
            return
        }
        pendingFile = file
        pendingPerform = perform
        requestDownload(file)
        observe(file)
    }

    /// Drops any pending wait without loading — the engine calls it on stop.
    func cancel() {
        clear()
    }

    private func clear() {
        pendingFile = nil
        pendingPerform = nil
    }

    /// Arms a one-shot `cloudStatus` observation on the pending file; on any change it re-reads
    /// on the main actor and either loads (now `.local`) or re-arms. The fired file's `id` rides
    /// through the `@Sendable` change hook (a `UUID`, unlike the non-`Sendable` file) so `react`
    /// can drop a wait superseded by a later `load`/`cancel` instead of re-arming on the new
    /// pending file — otherwise stale observations pile up as a slideshow advances through evicted
    /// files.
    private func observe(_ file: PlaylistFile) {
        let firedID = file.id
        withObservationTracking {
            _ = file.cloudStatus
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.react(firedID: firedID) }
        }
    }

    private func react(firedID: UUID) {
        // Identity guard: ignore a stale observation whose file a later `load`/`cancel` has since
        // replaced or cleared, rather than re-arming on the current `pendingFile`.
        guard let file = pendingFile, file.id == firedID, let perform = pendingPerform else { return }
        if file.cloudStatus == .local {
            clear()
            perform()
        } else {
            observe(file)
        }
    }
}
