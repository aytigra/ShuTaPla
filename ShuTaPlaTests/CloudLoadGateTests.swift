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

    @Test func cancelDropsPendingWait() async throws {
        let container = try makeContainer()
        let file = makeFile(.inCloud, in: container.mainContext)
        let gate = CloudLoadGate()
        var performed = false
        gate.load(file, perform: { performed = true }, requestDownload: { _ in })
        #expect(gate.pendingFile === file)

        gate.cancel()
        #expect(gate.pendingFile == nil)

        file.cloudStatus = .local                  // a superseded arrival must not load
        await settle(until: { performed })
        #expect(!performed)
    }
}
