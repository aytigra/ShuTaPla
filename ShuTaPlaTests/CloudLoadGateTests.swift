//
//  CloudLoadGateTests.swift
//  ShuTaPlaTests
//
//  Task 18, Step 6b — the evicted-file gate the playback engines share: a `.local`
//  file loads at once; an evicted one is held pending, its download requested, and the
//  deferred load runs only when the live cloud feed flips its `cloudStatus` to `.local`.
//  Driven directly with a synthetic `perform`/`requestDownload` pair, so no engine,
//  libmpv, or iCloud account is involved. The container is held for the whole body and
//  the observation reaction is awaited before asserting (trap classes 1 and 2).
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct CloudLoadGateTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeFile(_ status: CloudStatus, in context: ModelContext) -> PlaylistFile {
        let file = PlaylistFile(relativePath: "f", fileName: "f")
        context.insert(file)
        file.cloudStatus = status
        return file
    }

    /// Lets the gate's observation reaction (a `Task { @MainActor }` scheduled from the
    /// `withObservationTracking` change hook) run before asserting. Bounded, so it never hangs.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<20 where !condition() { await Task.yield() }
    }

    @Test func localFileLoadsAtOnce() throws {
        let container = try makeContainer()
        let file = makeFile(.local, in: container.mainContext)
        let gate = CloudLoadGate()
        var performed = false
        var requested: [UUID] = []
        gate.load(file, perform: { performed = true }, requestDownload: { requested.append($0.id) })
        #expect(performed)
        #expect(gate.pendingFile == nil)
        #expect(requested.isEmpty)
    }

    // The arrival reaction rests on observing `PlaylistFile.cloudStatus`. That property is
    // `@Transient` — which SwiftData's `@Model` macro would leave un-tracked — so its accessors
    // are hand-routed through the model's `_$observationRegistrar`, making `withObservationTracking`
    // (and every badge reader) see the live feed's flip to `.local`.
    @Test func evictedFileHoldsPendingThenLoadsOnArrival() async throws {
        let container = try makeContainer()
        let file = makeFile(.inCloud, in: container.mainContext)
        let gate = CloudLoadGate()
        var performed = false
        var requested: [UUID] = []
        gate.load(file, perform: { performed = true }, requestDownload: { requested.append($0.id) })
        #expect(gate.pendingFile === file)
        #expect(!performed)
        #expect(requested == [file.id])

        file.cloudStatus = .downloading            // still not local — the wait continues
        await settle(until: { performed })
        #expect(gate.pendingFile === file)
        #expect(!performed)

        file.cloudStatus = .local                  // arrival — the deferred load runs and pending clears
        await settle(until: { performed })
        #expect(performed)
        #expect(gate.pendingFile == nil)
    }

    // Supersession: a second `load` replaces the pending file before the first arrives. The old
    // file's one-shot observation is now stale. When it later fires, the gate must drop it — never
    // run the superseded `perform`, and never re-arm on the current pending file — so exactly the
    // current file's `perform` runs, exactly once, on its own arrival.
    @Test func supersededWaitDropsAndOnlyCurrentPerforms() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile(.inCloud, in: context)
        let b = makeFile(.inCloud, in: context)
        let gate = CloudLoadGate()
        var performedA = 0
        var performedB = 0
        gate.load(a, perform: { performedA += 1 }, requestDownload: { _ in })
        gate.load(b, perform: { performedB += 1 }, requestDownload: { _ in })   // supersedes A
        #expect(gate.pendingFile === b)

        // Flip the superseded file first, then the current one: A's stale reaction is enqueued onto
        // the main actor before B's, so B's `perform` running is a positive signal that the pump has
        // run a full cycle — A's reaction already ran (and was dropped) by the time B's does. That
        // makes `performedA == 0` a real drop, not a settle that returned before anything reacted.
        a.cloudStatus = .local                     // the superseded file arriving must not load
        b.cloudStatus = .local                     // the current file arrives — its perform runs once
        await settle(until: { performedB > 0 })
        #expect(performedB == 1)
        #expect(performedA == 0)                   // A was superseded — dropped, never performed
        #expect(gate.pendingFile == nil)
    }

    @Test func cancelDropsPendingWait() async throws {
        let container = try makeContainer()
        let file = makeFile(.inCloud, in: container.mainContext)
        let gate = CloudLoadGate()
        var performed = false
        gate.load(file, perform: { performed = true }, requestDownload: { _ in })
        #expect(gate.pendingFile === file)

        gate.cancel()
        #expect(gate.pendingFile == nil)

        // The cancelled file's arrival still fires its armed observation, enqueuing a (now stale)
        // reaction onto the main actor. A plain `Task` enqueued right after rides behind it, so its
        // flag flipping is a positive signal that the pump has run a full cycle — the stale reaction
        // already ran (and found nothing pending) by the time this does. `performed` staying false is
        // then a real drop, not a settle that returned before the reaction it rules out had run.
        file.cloudStatus = .local                  // a cancelled arrival must not load
        var pumpCycled = false
        Task { @MainActor in pumpCycled = true }
        await settle(until: { pumpCycled })
        #expect(!performed)
    }
}
