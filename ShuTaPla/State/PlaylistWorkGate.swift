//
//  PlaylistWorkGate.swift
//  ShuTaPla
//
//  The per-playlist exclusion between file ops, background tasks and a playlist delete.
//

import Foundation

/// Orders the work on one playlist, keyed by its id. The background task is a re-scan or a new
/// playlist's tag derive. Rules:
///
/// - File ops on one playlist run side by side.
/// - An op excludes the background task: `beginOp` cancels and awaits the tracked task, and a scan
///   requested during an op is deferred and runs once, after the last op ends (`endOp`).
/// - A delete waits for the ops in flight and the tracked task (`waitForWork`). Once it begins, no
///   op or scan starts on the playlist and a deferred scan is dropped.
/// - A tracked task supersedes the playlist's previous one and ends only after it: a cancelled
///   scan past its commit decision still applies, so awaiting the entry awaits every task of the
///   playlist. The entry stays until its task ends.
///
/// Only the deleting ids are observed: sidebar rows show them.
@MainActor
@Observable
final class PlaylistWorkGate {
    private var deletingIDs: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var opCounts: [UUID: Int] = [:]
    @ObservationIgnored private var deferredScans: Set<UUID> = []
    @ObservationIgnored private var drains: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored var onDeleteEnded: (() -> Void)?

    func isDeleting(_ id: UUID) -> Bool { deletingIDs.contains(id) }

    var isDeletingAny: Bool { deletingIDs.isNotEmpty }

    func task(for id: UUID) -> Task<Void, Never>? { tasks[id] }

    func opCount(for id: UUID) -> Int { opCounts[id] ?? 0 }

    /// Runs `work` as the playlist's tracked task, cancelling the one it supersedes.
    func track(_ id: UUID, _ work: @escaping () async -> Void) -> Task<Void, Never> {
        let superseded = tasks[id]
        superseded?.cancel()
        let task = Task {
            await work()
            await superseded?.value
        }
        tasks[id] = task
        Task {
            await task.value
            if tasks[id] == task { tasks[id] = nil }
        }
        return task
    }

    /// Whether a scan of the playlist starts now. One requested during an op is deferred to the
    /// end of the last op; one requested during a delete is dropped.
    func requestScan(_ id: UUID) -> Bool {
        guard !isDeleting(id) else { return false }
        guard opCounts[id] == nil else {
            deferredScans.insert(id)
            return false
        }
        return true
    }

    /// Claims the playlist for an op. Returns `false`, holding no claim, while it is being
    /// deleted, also when the delete began while the op awaited the tracked task. A task that
    /// ended in the turn before still has its entry, so the op defers one more scan: a rare extra
    /// re-scan, with a correct result. Each `true` is paired with an `endOp`.
    func beginOp(_ id: UUID) async -> Bool {
        guard !isDeleting(id) else { return false }
        opCounts[id, default: 0] += 1
        if let task = tasks[id] {
            task.cancel()
            deferredScans.insert(id)
            await task.value
            if isDeleting(id) {
                _ = endOp(id)
                return false
            }
        }
        return true
    }

    /// Ends an op's claim. Returns whether the caller runs a deferred scan: the playlist's last op
    /// ended and a scan was requested meanwhile.
    func endOp(_ id: UUID) -> Bool {
        guard opCounts.decrementCount(forKey: id) == 0 else { return false }
        drains.removeValue(forKey: id)?.resume()
        return deferredScans.remove(id) != nil
    }

    /// Marks the playlist deleted and cancels its tracked task. Returns `false` for a playlist
    /// already being deleted. Each `true` is paired with `waitForWork` and then `endDelete`.
    func beginDelete(_ id: UUID) -> Bool {
        guard deletingIDs.insert(id).inserted else { return false }
        tasks[id]?.cancel()
        deferredScans.remove(id)
        return true
    }

    /// Waits for the playlist's ops in flight, then for its tracked task.
    func waitForWork(on id: UUID) async {
        if opCounts[id] != nil {
            await withCheckedContinuation { drains[id] = $0 }
        }
        await tasks[id]?.value
    }

    func endDelete(_ id: UUID) {
        deletingIDs.remove(id)
        onDeleteEnded?()
    }

    /// Cancels the tracked tasks of `ids`. Their entries stay until the tasks end, so an op still
    /// awaits a scan past its commit decision.
    func cancel(_ ids: some Sequence<UUID>) {
        for id in ids { tasks[id]?.cancel() }
    }
}
