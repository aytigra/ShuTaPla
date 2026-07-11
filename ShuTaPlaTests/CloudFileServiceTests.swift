//
//  CloudFileServiceTests.swift
//  ShuTaPlaTests
//
//  The live-feed apply core of `CloudFileService`: given normalized status updates
//  keyed by relative path, it flips `cloudStatus` on the matching model and leaves
//  every other file untouched. Driven directly through the update seam, so no live
//  `NSMetadataQuery` or iCloud account is involved.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

/// A one-shot flag for `withObservationTracking`'s `@Sendable` `onChange`, which can't mutate a
/// captured `var`. The callback runs synchronously on the main actor within the mutation.
private final class Fired: @unchecked Sendable { var value = false }

@MainActor
struct CloudFileServiceTests {

    /// A fresh in-memory container with the full app schema, held for the whole test body
    /// so its `mainContext` never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self,
            AppStateModel.self, GlobalSettings.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeFile(_ path: String, in context: ModelContext) -> PlaylistFile {
        let file = PlaylistFile(relativePath: path, fileName: path)
        context.insert(file)
        return file
    }

    @Test func applyFlipsMatchingFileAndLeavesOthers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)
        let b = makeFile("sub/b.mp4", in: context)
        let c = makeFile("c.mp4", in: context)

        let service = CloudFileService()
        service.apply(
            [
                CloudStatusUpdate(relativePath: "a.mp4", status: .inCloud),
                CloudStatusUpdate(relativePath: "sub/b.mp4", status: .downloading),
            ],
            to: [a, b, c]
        )

        #expect(a.cloudStatus == .inCloud)     // matched by path
        #expect(b.cloudStatus == .downloading) // matched, nested path
        #expect(c.cloudStatus == .local)       // unmentioned — untouched
    }

    @Test func applyIgnoresUpdatesWithNoMatchingFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)

        let service = CloudFileService()
        service.apply([CloudStatusUpdate(relativePath: "ghost.mp4", status: .inCloud)], to: [a])

        #expect(a.cloudStatus == .local)   // the one file is left alone
    }

    @Test func applyRewritesStatusOnRepeatUpdates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)

        let service = CloudFileService()
        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .inCloud)], to: [a])
        #expect(a.cloudStatus == .inCloud)

        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .downloading)], to: [a])
        #expect(a.cloudStatus == .downloading)   // a later event supersedes the earlier one

        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .local)], to: [a])
        #expect(a.cloudStatus == .local)         // download completed → back to local
    }

    @Test func applyDoesNotInvalidateObserversOnUnchangedStatus() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)

        let service = CloudFileService()
        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .inCloud)], to: [a])
        #expect(a.cloudStatus == .inCloud)

        // A repeated metadata tick reports the same status. Feeding it must not invalidate the
        // observer — with the match-all predicate every file is fed every tick, so an unchanged
        // write would re-render the whole Manager list + gallery on any metadata change. `onChange`
        // is `@Sendable`, so record the fire through a reference (it runs synchronously on the main
        // actor within the mutation — single-threaded in practice).
        let invalidated = Fired()
        withObservationTracking { _ = a.cloudStatus } onChange: { invalidated.value = true }
        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .inCloud)], to: [a])
        #expect(!invalidated.value)   // unchanged status → no redundant invalidation

        // A genuine transition still notifies observers — the gate suppresses only no-op writes.
        let changed = Fired()
        withObservationTracking { _ = a.cloudStatus } onChange: { changed.value = true }
        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .local)], to: [a])
        #expect(changed.value)
    }

    // The caller resolves the file URL under the playlist folder's live scoped session (the
    // coordinator's `url(for:)`); the service just forwards it to the requester once. The
    // "no playlist / unresolvable folder → no-op" guard lives with the resolver, in
    // `PlaybackCoordinatorTests` (`setCurrentFile` requests nothing without an open session).
    @Test func requestDownloadForwardsURLToRequester() throws {
        let url = URL(fileURLWithPath: "/folder/clip.mp4")
        var requested: [URL] = []
        let service = CloudFileService(requester: { requested.append($0) })
        service.requestDownload(at: url)

        #expect(requested == [url])   // exactly one request, for the given URL
    }
}
