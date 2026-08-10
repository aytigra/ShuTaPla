//
//  TagFilterTests.swift
//  ShuTaPlaTests
//
//  The four-field tag filter as store rows: the field key over the four lists, the derived summary,
//  the rewrite/drop passes a playlist-wide tag edit runs — and the ownership rules that keep a
//  filter reachable. `TagFilter` and `SavedSearch` cascade into each other, so every teardown path
//  has to be verified from both ends and where they converge.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct TagFilterTests {

    /// Holds the container for the whole test body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        return try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A playlist applying a filter that a search was saved over — the state the teardown rules
    /// delete from, and the one where both of the playlist's cascades reach the same two rows.
    private func seed(in context: ModelContext) throws -> (playlist: Playlist, filter: TagFilter, search: SavedSearch) {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        let filter = TagFilter()
        filter.mustHaveAll = ["beach"]
        let search = SavedSearch(name: "Beach shots")
        context.insert(playlist)
        context.insert(filter)
        context.insert(search)
        search.playlist = playlist
        search.filter = filter
        playlist.currentFilter = filter
        try context.save()
        return (playlist, filter, search)
    }

    private func counts(in context: ModelContext) throws -> (filters: Int, searches: Int) {
        (try context.fetchCount(FetchDescriptor<TagFilter>()),
         try context.fetchCount(FetchDescriptor<SavedSearch>()))
    }

    // MARK: - The four lists

    @Test func subscriptReachesEveryFieldIndependently() {
        let filter = TagFilter()
        for field in TagFilterField.allCases { filter[field] = [field.rawValue] }
        #expect(filter.mustHaveAll == ["mustHaveAll"])
        #expect(filter.mustHaveAny == ["mustHaveAny"])
        #expect(filter.mustNotHaveAll == ["mustNotHaveAll"])
        #expect(filter.mustNotHaveAny == ["mustNotHaveAny"])
        #expect(TagFilterField.allCases.map { filter[$0] } == TagFilterField.allCases.map { [$0.rawValue] })
    }

    @Test func isEmptyOnlyWhenEveryListIsEmpty() {
        let filter = TagFilter()
        #expect(filter.isEmpty)
        // A single tag in any one of the four is enough to make the filter mean something.
        for field in TagFilterField.allCases {
            filter[field] = ["a"]
            #expect(!filter.isEmpty)
            filter[field] = []
        }
        #expect(filter.isEmpty)
    }

    /// What the summary line walks, and what `normalizedFields` is built from: the non-empty lists
    /// only, as typed, in `allCases` order whatever order they were filled in.
    @Test func filledFieldsAreTheNonEmptyListsInFieldOrder() {
        let filter = TagFilter()
        filter.mustNotHaveAny = ["C"]
        filter.mustHaveAll = ["A", "B"]
        let filled = filter.filledFields
        #expect(filled.map(\.field) == [.mustHaveAll, .mustNotHaveAny])
        #expect(filled.map(\.tags) == [["A", "B"], ["C"]])
    }

    @Test func normalizedFieldsIgnoreOrderAndCase() {
        let one = TagFilter()
        one.mustHaveAny = ["Beach", "sun"]
        let other = TagFilter()
        other.mustHaveAny = ["SUN", "beach"]
        #expect(one.normalizedFields == other.normalizedFields)

        // Only the filled fields are keys — an empty field is absent, not an empty set, which is
        // what lets the predicate builder read a missing key as "no subquery for this field".
        #expect(Set(one.normalizedFields.keys) == [.mustHaveAny])
        #expect(TagFilter().normalizedFields.isEmpty)

        // The same tags in a *different* field are a different combination.
        let moved = TagFilter()
        moved.mustHaveAll = ["beach", "sun"]
        #expect(one.normalizedFields != moved.normalizedFields)
    }

    // MARK: - Playlist-wide tag edits

    @Test func rewriteMapsEveryListAndDedupes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)
        seeded.filter.mustHaveAll = ["old", "keep"]
        seeded.filter.mustNotHaveAny = ["old", "OLD"]

        seeded.playlist.rewriteFilterTag { TagParser.sameTag($0, "old") ? "new" : $0 }

        #expect(seeded.filter.mustHaveAll == ["new", "keep"])
        // Two casings of the renamed tag collapse to one.
        #expect(seeded.filter.mustNotHaveAny == ["new"])
    }

    @Test func rewriteReachesASavedSearchsFilterThatIsNotApplied() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)

        // A second search, saved but not applied — its filter is reached only through the search.
        let parked = TagFilter()
        parked.mustHaveAny = ["old"]
        let search = SavedSearch(name: "Parked", listOrder: 1)
        context.insert(parked)
        context.insert(search)
        search.playlist = seeded.playlist
        search.filter = parked
        try context.save()

        seeded.playlist.rewriteFilterTag { TagParser.sameTag($0, "old") ? "new" : $0 }
        #expect(parked.mustHaveAny == ["new"])
    }

    @Test func dropKeepsAFilterThatStillHasATagAnywhere() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)
        seeded.filter.mustHaveAny = ["keep"]   // must-have-all is ["beach"]

        seeded.playlist.dropFilterTag("beach")
        try context.save()

        #expect(seeded.filter.mustHaveAll.isEmpty)
        #expect(seeded.filter.mustHaveAny == ["keep"])
        #expect(try counts(in: context) == (filters: 1, searches: 1))
    }

    @Test func dropDeletesAFilterLeftEmptyAndTheSearchOverIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)   // must-have-all is ["beach"] and nothing else

        seeded.playlist.dropFilterTag("beach")
        try context.save()

        // A search over no lists matches everything and names a combination that no longer exists.
        #expect(try counts(in: context) == (filters: 0, searches: 0))
        #expect(seeded.playlist.currentFilter == nil)
    }

    // MARK: - Ownership and teardown

    @Test func deletingTheFilterReapsTheSearchSavedOverIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)

        context.delete(seeded.filter)
        try context.save()

        #expect(try counts(in: context) == (filters: 0, searches: 0))
        #expect(seeded.playlist.currentFilter == nil)
    }

    @Test func deletingTheSearchReapsItsFilterAndLeavesThePlaylistUnfiltered() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)

        context.delete(seeded.search)
        try context.save()

        // Deleting the active search leaves the playlist unfiltered rather than keeping its tags
        // as an ad-hoc filter.
        #expect(try counts(in: context) == (filters: 0, searches: 0))
        #expect(seeded.playlist.currentFilter == nil)
    }

    @Test func deletingThePlaylistConvergesBothCascadesWithoutOrphansOrTraps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)

        // `currentFilter` → the search, and `savedSearches` → the same filter: the second traversal
        // lands on an already-deleted row.
        context.delete(seeded.playlist)
        try context.save()

        #expect(try counts(in: context) == (filters: 0, searches: 0))
        #expect(try context.fetchCount(FetchDescriptor<Playlist>()) == 0)
    }

    /// The filtering suites re-filter through `applyTagFilter`, so it has to dispose of the outgoing
    /// row the way the app's own apply does — otherwise the fixtures accumulate rows with neither
    /// `playlist` nor `savedSearch`, the unreachable state this model says must never exist.
    @Test func reFilteringThroughTheHelperDisposesOfAReplacedAdHocRowOnly() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)   // applying ["beach"], with a search saved over it

        applyTagFilter(to: seeded.playlist, in: context, mustHaveAny: ["sun"])
        try context.save()
        // The outgoing row was the search's own, so it stays reachable through the search.
        #expect(try counts(in: context) == (filters: 2, searches: 1))

        applyTagFilter(to: seeded.playlist, in: context, mustHaveAny: ["moon"])
        try context.save()
        // This one was ad-hoc — nothing reaches it once it stops being applied.
        #expect(try counts(in: context) == (filters: 2, searches: 1))
        #expect(seeded.playlist.currentFilter?.mustHaveAny == ["moon"])
        #expect(seeded.search.filter?.mustHaveAll == ["beach"])
    }

    @Test func aSavedSearchsFilterSurvivesThePlaylistApplyingAnother() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let seeded = try seed(in: context)

        // Being applied is not ownership — reassigning `currentFilter` fires no delete rule.
        let other = TagFilter()
        other.mustHaveAll = ["sunset"]
        context.insert(other)
        seeded.playlist.currentFilter = other
        try context.save()

        #expect(try counts(in: context) == (filters: 2, searches: 1))
        #expect(seeded.search.filter?.mustHaveAll == ["beach"])
        // The outgoing filter is no longer applied, but stays reachable through its search.
        #expect(seeded.filter.playlist == nil)
        #expect(seeded.filter.savedSearch === seeded.search)
    }
}
