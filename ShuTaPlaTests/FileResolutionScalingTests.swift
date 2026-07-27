//
//  FileResolutionScalingTests.swift
//  ShuTaPlaTests
//
//  Delete-crash task, follow-up R2 — the measurement that decides whether the P1 fix's
//  `ModelContext.file(for:)` fetch is safe on the row-render hot path. `file(for:)` runs once per
//  visible Manager row per `body` evaluation; the fix replaced an O(1) `model(for:)` registered-object
//  lookup with a `FetchDescriptor` keyed on `$0.persistentModelID == id`. The open question was whether
//  the store resolves that on the entity's primary key (an indexed lookup — constant per call, so a
//  full-list render stays O(N)) or by scanning rows (O(N) per call, so a render trends to O(N²)).
//
//  The experiment: resolve every seeded id once at two row counts a 10x apart and compare the
//  *per-call* cost. An index-backed lookup barely moves as N grows; a row scan grows ~10x with it. A
//  primary-key comparison is index-backed, so this asserts the per-call cost stays well under linear —
//  and stands as the regression guard should the predicate ever drift onto a non-indexed key.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct FileResolutionScalingTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Seeds `count` saved files and returns the mean nanoseconds to resolve one id through
    /// `file(for:)`, averaged over resolving every seeded id once. Resolving the whole set (not one
    /// id repeatedly) makes a row scan pay its average cost each call, so a scan's per-call time
    /// scales with `count` while an indexed lookup does not.
    private func meanResolveNanos(count: Int) throws -> Double {
        let container = try makeContainer()
        let context = container.mainContext
        for i in 0..<count {
            context.insert(PlaylistFile(relativePath: "f\(i).mp4", fileName: "f\(i).mp4", taggingStatus: .valid, sortOrder: i))
        }
        try context.save()

        var descriptor = FetchDescriptor<PlaylistFile>()
        descriptor.propertiesToFetch = []
        let ids = try context.fetch(descriptor).map(\.persistentModelID)

        // Warm the query plan / caches so the timed pass measures steady state, not first-touch.
        for id in ids { _ = context.file(for: id) }

        let elapsed = ContinuousClock().measure {
            for id in ids { _ = context.file(for: id) }
        }
        return Double(elapsed.components.attoseconds) / 1e9 / Double(count)
    }

    /// Per-call `file(for:)` cost must stay well under linear as the row count grows 10x — proving the
    /// `persistentModelID` predicate resolves on the primary-key index rather than scanning rows.
    @Test func resolutionCostStaysSublinearAsRowsGrow() throws {
        let small = try meanResolveNanos(count: 300)
        let large = try meanResolveNanos(count: 3_000)
        let ratio = large / small

        // A row scan would grow ~10x with the 10x rows; an indexed lookup stays roughly flat. The 4x
        // ceiling clears index-backed noise (allocation, ARC, plan caching) while a scan's ~10x fails it.
        #expect(
            ratio < 4,
            "file(for:) per-call cost scaled \(String(format: "%.2f", ratio))x for 10x rows (\(String(format: "%.0f", small))ns → \(String(format: "%.0f", large))ns) — expected sublinear (index-backed); ~10x would indicate a row scan"
        )
    }
}
