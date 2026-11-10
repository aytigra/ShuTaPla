//
//  PlaylistWorkGateTests.swift
//  ShuTaPlaTests
//
//  The per-playlist exclusion between file ops, background tasks and a delete, on bare ids.
//

import Foundation
import Testing
@testable import ShuTaPla

@MainActor
struct PlaylistWorkGateTests {
    let gate = PlaylistWorkGate()
    let id = UUID()

    /// Lets queued main-actor tasks run, so a test can check that an awaiting one did not finish.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func opsOnOnePlaylistRunSideBySide() async {
        #expect(await gate.beginOp(id))
        #expect(await gate.beginOp(id))
        #expect(gate.opCount(for: id) == 2)
    }

    @Test func aScanWithNoOpStartsAtOnce() {
        #expect(gate.requestScan(id))
    }

    @Test func scansRequestedDuringOpsRunOnceAfterTheLastOp() async {
        _ = await gate.beginOp(id)
        _ = await gate.beginOp(id)
        #expect(!gate.requestScan(id))
        #expect(!gate.requestScan(id))

        #expect(!gate.endOp(id))
        #expect(gate.endOp(id))
        #expect(gate.opCount(for: id) == 0)
    }

    @Test func anOpOnAnotherPlaylistDefersNoScan() async {
        _ = await gate.beginOp(UUID())
        #expect(gate.requestScan(id))
    }

    @Test func anOpCancelsAndAwaitsTheTrackedTaskThenDefersItsRerun() async throws {
        let hold = Hold()
        var cancelled = false
        _ = gate.track(id) {
            await hold.wait()
            cancelled = Task.isCancelled
        }
        try await waitUntil { hold.isWaiting }
        var began: Bool?
        let op = Task { began = await gate.beginOp(id) }
        await settle()
        #expect(began == nil)

        hold.open()
        await op.value
        #expect(cancelled)
        #expect(began == true)
        #expect(gate.endOp(id))
    }

    @Test func aTrackedTaskEndsAfterTheOneItSupersedes() async throws {
        let hold = Hold()
        var firstCancelled = false
        let first = gate.track(id) {
            await hold.wait()
            firstCancelled = Task.isCancelled
        }
        try await waitUntil { hold.isWaiting }
        let second = gate.track(id) {}
        var secondEnded = false
        let watcher = Task { await second.value; secondEnded = true }
        await settle()
        #expect(!secondEnded)
        #expect(gate.task(for: id) == second)

        hold.open()
        await watcher.value
        #expect(firstCancelled)
        await first.value
        try await waitUntil { gate.task(for: id) == nil }
    }

    @Test func cancelReachesOnlyTheNamedPlaylists() async throws {
        let other = UUID()
        let (hold, otherHold) = (Hold(), Hold())
        var cancelled: [UUID: Bool] = [:]
        let task = gate.track(id) { await hold.wait(); cancelled[id] = Task.isCancelled }
        let otherTask = gate.track(other) { await otherHold.wait(); cancelled[other] = Task.isCancelled }
        try await waitUntil { hold.isWaiting && otherHold.isWaiting }

        gate.cancel([id])
        #expect(gate.task(for: id) != nil)
        hold.open()
        otherHold.open()
        await task.value
        await otherTask.value
        #expect(cancelled == [id: true, other: false])
    }

    @Test func aDeleteRefusesOpsScansAndARepeat() async {
        #expect(gate.beginDelete(id))
        #expect(gate.isDeleting(id))
        #expect(gate.isDeletingAny)
        #expect(!gate.beginDelete(id))
        #expect(!(await gate.beginOp(id)))
        #expect(!gate.requestScan(id))
        #expect(gate.opCount(for: id) == 0)

        gate.endDelete(id)
        #expect(!gate.isDeletingAny)
    }

    @Test func aDeleteDropsTheScanDeferredByAnOp() async {
        _ = await gate.beginOp(id)
        _ = gate.requestScan(id)
        _ = gate.beginDelete(id)

        #expect(!gate.endOp(id))
    }

    @Test func aDeleteWaitsForTheOpsInFlight() async {
        _ = await gate.beginOp(id)
        _ = await gate.beginOp(id)
        _ = gate.beginDelete(id)
        var waited = false
        let wait = Task { await gate.waitForWork(on: id); waited = true }

        _ = gate.endOp(id)
        await settle()
        #expect(!waited)
        _ = gate.endOp(id)
        await wait.value
        #expect(waited)
    }

    @Test func aDeleteWaitsForTheCancelledTrackedTask() async throws {
        let hold = Hold()
        var cancelled = false
        _ = gate.track(id) { await hold.wait(); cancelled = Task.isCancelled }
        try await waitUntil { hold.isWaiting }
        _ = gate.beginDelete(id)
        var waited = false
        let wait = Task { await gate.waitForWork(on: id); waited = true }
        await settle()
        #expect(!waited)

        hold.open()
        await wait.value
        #expect(cancelled)
    }

    /// An op that awaited the tracked task when the delete began drops its claim, which releases
    /// the delete's wait.
    @Test func anOpAwaitingTheTaskWhenADeleteBeginsIsRefused() async throws {
        let hold = Hold()
        _ = gate.track(id) { await hold.wait() }
        try await waitUntil { hold.isWaiting }
        var began: Bool?
        let op = Task { began = await gate.beginOp(id) }
        try await waitUntil { gate.opCount(for: id) == 1 }
        _ = gate.beginDelete(id)
        let wait = Task { await gate.waitForWork(on: id) }

        hold.open()
        await op.value
        await wait.value
        #expect(began == false)
        #expect(gate.opCount(for: id) == 0)
    }
}

/// Work that waits until `open()`.
@MainActor
private final class Hold {
    private(set) var isWaiting = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
