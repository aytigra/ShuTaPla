//
//  TagFilterPredicateTests.swift
//  ShuTaPlaTests
//
//  The four-field tag filter's rules and evaluation shape, exercised through the query layer that
//  ships them: a `TagFilter` row is attached to a playlist and the assertions read
//  `ModelContext.sequence(of:)`. Each filled field contributes one subquery over `file.tags`,
//  compared against a threshold, AND-joined with the scope and with each other.
//
//  Building the predicate here instead — a local copy of the composition under test — is what this
//  file must not do: it would pin the rules against the copy, leaving the shipped builder free to
//  regress with every case green. For the same reason the cost test derives its expected count from
//  an independent pass in Swift rather than from evaluating the very predicate it measures.
//
//  The fields are separate `#Predicate`s nested into one another with `.evaluate(_:)` rather than a
//  single `#Predicate` spelling out all four, because one `#Predicate` cannot hold them: the macro
//  expands to a single deeply nested generic expression, and the type-checker gives up ("unable to
//  type-check this expression in reasonable time") at roughly three `file.tags.filter { … }.count`
//  subqueries or four conjuncts — it is the whole expression's complexity, not the subqueries as
//  such. Small predicates folded pairwise stay far under that ceiling, and SwiftData translates the
//  nested node to SQL, so the fetch stays a single store-side query returning identifiers.
//
//  Composing at runtime also means only the fields somebody filled are built at all: an empty field
//  contributes no subquery, and an all-empty filter *is* the scalar predicate. Every threshold
//  counts its field's deduped, lowercased names, so a tag typed twice (or in two casings) can never
//  make must-have-all unsatisfiable.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct TagFilterPredicateTests {

    /// Holds the container for the whole body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Every combination of a/b/c the four rules distinguish, plus a skipped file carrying `a b` —
    /// the one row no field may ever admit.
    private func seededPlaylist(in context: ModelContext) throws -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        insertFile("none", tags: [], status: .untagged, order: 0, to: playlist, in: context)
        insertFile("a", tags: ["a"], status: .valid, order: 1, to: playlist, in: context)
        insertFile("b", tags: ["b"], status: .valid, order: 2, to: playlist, in: context)
        insertFile("ab", tags: ["a", "b"], status: .valid, order: 3, to: playlist, in: context)
        insertFile("abc", tags: ["a", "b", "c"], status: .valid, order: 4, to: playlist, in: context)
        insertFile("c", tags: ["c"], status: .valid, order: 5, to: playlist, in: context)
        insertFile("skip", tags: ["a", "b"], status: .valid, skipped: true, order: 6, to: playlist, in: context)
        try context.save()
        return playlist
    }

    /// Attaches a filter and saves — the derivation fetches with `includePendingChanges: false`, so
    /// an unsaved filter row would not be seen.
    private func applyFilter(
        to playlist: Playlist, in context: ModelContext,
        mustHaveAll: [String] = [], mustHaveAny: [String] = [],
        mustNotHaveAll: [String] = [], mustNotHaveAny: [String] = []
    ) throws {
        applyTagFilter(to: playlist, in: context, mustHaveAll: mustHaveAll, mustHaveAny: mustHaveAny,
                       mustNotHaveAll: mustNotHaveAll, mustNotHaveAny: mustNotHaveAny)
        try context.save()
    }

    /// The sequence under the playlist's current filter, by filename in `sortOrder`.
    private func sequenceNames(of playlist: Playlist, in context: ModelContext) -> [String] {
        context.sequence(of: playlist).compactMap { (context.model(for: $0) as? PlaylistFile)?.fileName }
    }

    @Test func eachFieldAloneMatchesItsRule() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // Carries every listed tag.
        try applyFilter(to: playlist, in: context, mustHaveAll: ["a", "b"])
        #expect(sequenceNames(of: playlist, in: context) == ["ab", "abc"])

        // Carries at least one.
        try applyFilter(to: playlist, in: context, mustHaveAny: ["a", "b"])
        #expect(sequenceNames(of: playlist, in: context) == ["a", "b", "ab", "abc"])

        // Missing at least one — dropped only when it carries every one.
        try applyFilter(to: playlist, in: context, mustNotHaveAll: ["a", "b"])
        #expect(sequenceNames(of: playlist, in: context) == ["none", "a", "b", "c"])

        // Carries none of them — the untagged file is included, an honest "has none of them".
        try applyFilter(to: playlist, in: context, mustNotHaveAny: ["a", "b"])
        #expect(sequenceNames(of: playlist, in: context) == ["none", "c"])
    }

    @Test func oneTagMakesTheTwoNegativesCoincide() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // With one name, "missing all of it" and "has none of it" are the same threshold.
        let expected = ["none", "b", "c"]
        try applyFilter(to: playlist, in: context, mustNotHaveAll: ["a"])
        #expect(sequenceNames(of: playlist, in: context) == expected)

        try applyFilter(to: playlist, in: context, mustNotHaveAny: ["a"])
        #expect(sequenceNames(of: playlist, in: context) == expected)
    }

    @Test func anEmptyFilterRowMatchesEverythingNotSkipped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // No field contributes a subquery, so the composition *is* the scalar scope — which still
        // excludes the skipped file, as every filter does.
        try applyFilter(to: playlist, in: context)
        #expect(sequenceNames(of: playlist, in: context) == ["none", "a", "b", "ab", "abc", "c"])
    }

    @Test func fieldsAreAndJoined() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // a AND (b OR c) — the combination only separate lists can express.
        try applyFilter(to: playlist, in: context, mustHaveAll: ["a"], mustHaveAny: ["b", "c"])
        #expect(sequenceNames(of: playlist, in: context) == ["ab", "abc"])

        // All four at once: has a, has b or c, isn't the full (a,b,c) set, and never carries x.
        try applyFilter(to: playlist, in: context, mustHaveAll: ["a"], mustHaveAny: ["b", "c"],
                        mustNotHaveAll: ["a", "b", "c"], mustNotHaveAny: ["x"])
        #expect(sequenceNames(of: playlist, in: context) == ["ab"])
    }

    @Test func aTagInAPositiveAndANegativeFieldMatchesNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // A contradiction is allowed rather than prevented or warned about: the fields are joined
        // as written, and an empty sequence is the honest answer.
        try applyFilter(to: playlist, in: context, mustHaveAll: ["a"], mustNotHaveAny: ["a"])
        #expect(sequenceNames(of: playlist, in: context) == [])
        #expect(!context.sequenceNotEmpty(in: playlist))
    }

    @Test func thresholdsCountDedupedNames() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // A repeated name in two casings must not raise must-have-all's threshold past what any
        // file can reach — otherwise the field would be unsatisfiable.
        try applyFilter(to: playlist, in: context, mustHaveAll: ["A", "a"])
        #expect(sequenceNames(of: playlist, in: context) == ["a", "ab", "abc"])

        // Likewise must-not-have-all: a deduped single name means "missing that one tag".
        try applyFilter(to: playlist, in: context, mustNotHaveAll: ["A", "a"])
        #expect(sequenceNames(of: playlist, in: context) == ["none", "b", "c"])
    }

    @Test func sortOrderBoundNarrowsAFilteredSequence() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = try seededPlaylist(in: context)

        // `resumeTarget`'s bound rides the same predicate as the filter fields: the first match at
        // or after the bound, and a wrap to the filtered set's first when nothing qualifies.
        try applyFilter(to: playlist, in: context, mustHaveAny: ["a", "b"])
        #expect(context.resumeTarget(of: playlist, atOrAfter: 3)?.fileName == "ab")
        #expect(context.resumeTarget(of: playlist, atOrAfter: 99)?.fileName == "a")
    }

    /// Matching rows prove the nested predicate *runs*, not that it runs as SQL — SwiftData could be
    /// materializing every row and filtering in memory, which would cost `fetchCount` and
    /// `fetchLimit: 1` their point. A flat one-subquery `#Predicate` is known to translate, so the
    /// nested tree costing the same order over a sizable tagged playlist is what says it takes the
    /// same path; an in-memory fallback would show up as orders of magnitude, not tens of percent.
    @Test func nestedPredicateCostsLikeSQLNotLikeAnInMemoryFallback() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        var cache = context.tagsByNormalizedName()
        for index in 0..<2000 {
            let file = PlaylistFile(
                relativePath: "f\(index)", fileName: "f\(index)",
                taggingStatus: .valid, isSkipped: false, sortOrder: index
            )
            file.playlist = playlist
            context.insert(file)
            file.tags = context.tags(named: ["t\(index % 40)", "u\(index % 7)"], cache: &cache)
        }
        try context.save()

        let pid = playlist.persistentModelID
        print("seeded \(try context.fetchCount(FetchDescriptor<PlaylistFile>())) files, "
              + "\(try context.fetchCount(FetchDescriptor<ShuTaPla.Tag>())) distinct tags, 2 tags each")

        /// 20 rounds of the shipped derivation, asserting the row count each round.
        func timeSequence(expecting count: Int) -> Double {
            let start = ContinuousClock.now
            for _ in 0..<20 { #expect(context.sequence(of: playlist).count == count) }
            return Double((ContinuousClock.now - start).components.attoseconds) / 1e18
        }

        /// The same 20 rounds against a hand-written flat predicate, fetched the way the derivation
        /// fetches — the known-translating baseline the composed tree is measured against.
        func timeFlat(_ predicate: Predicate<PlaylistFile>, expecting count: Int) throws -> Double {
            var descriptor = FetchDescriptor<PlaylistFile>(predicate: predicate, sortBy: [SortDescriptor(\.sortOrder)])
            descriptor.includePendingChanges = false
            let start = ContinuousClock.now
            for _ in 0..<20 { #expect(try context.fetchIdentifiers(descriptor).count == count) }
            return Double((ContinuousClock.now - start).components.attoseconds) / 1e18
        }

        let names = ["t0"]
        let flat = #Predicate<PlaylistFile> { file in
            file.playlist?.persistentModelID == pid && !file.isSkipped
                && file.tags.filter { names.contains($0.normalizedName) }.count >= 1
        }
        _ = try timeFlat(flat, expecting: 50)  // warm the statement cache before anything is measured
        let flatSeconds = try timeFlat(flat, expecting: 50)

        // A real four-field combination: four nested subqueries, folded to depth four. The expected
        // count comes from an independent pass in Swift over the same rows, so the store and a
        // plain reading of the four rules must agree — a silently wrong translation fails here
        // rather than being timed as if correct.
        try applyFilter(to: playlist, in: context, mustHaveAll: ["u0"], mustHaveAny: ["t0", "t1", "t2"],
                        mustNotHaveAll: ["t0", "u0"], mustNotHaveAny: ["t2"])
        let expected = try context.fetch(FetchDescriptor<PlaylistFile>()).count { file in
            let tags = Set(file.tags.map(\.normalizedName))
            return tags.isSuperset(of: ["u0"])
                && !tags.isDisjoint(with: ["t0", "t1", "t2"])
                && !tags.isSuperset(of: ["t0", "u0"])
                && tags.isDisjoint(with: ["t2"])
        }
        #expect(expected > 0 && expected < 2000, "combination must actually discriminate, matched \(expected)")
        _ = timeSequence(expecting: expected)
        let combinationSeconds = timeSequence(expecting: expected)
        let combinationReport = "four-field sequence x20 over 2000 rows (\(expected) matched) — flat \(flatSeconds)s, combination \(combinationSeconds)s, ratio \(combinationSeconds / flatSeconds)"
        print(combinationReport)
        #expect(combinationSeconds < flatSeconds * 5, "\(combinationReport)")

        // An all-empty filter row composes down to the scalar predicate, so it should cost what
        // carrying no filter row at all costs.
        playlist.currentFilter = nil
        try context.save()
        _ = timeSequence(expecting: 2000)
        let unfilteredSeconds = timeSequence(expecting: 2000)

        try applyFilter(to: playlist, in: context)
        let emptySeconds = timeSequence(expecting: 2000)
        let emptyReport = "all-empty sequence x20 over 2000 rows — no filter row \(unfilteredSeconds)s, empty filter row \(emptySeconds)s, ratio \(emptySeconds / unfilteredSeconds)"
        print(emptyReport)
        #expect(emptySeconds < unfilteredSeconds * 2, "\(emptyReport)")
    }
}
