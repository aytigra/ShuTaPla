//
//  FilterStateTests.swift
//  ShuTaPlaTests
//
//  The pure tag/triage-filter transitions on `FilterState` — a `nonisolated` value type, so these
//  need no main actor or model context.
//

import Testing
import Foundation
@testable import ShuTaPla

struct FilterStateTests {

    @Test func toggleTagAddsThenRemovesByCaseInsensitiveEquality() {
        var state = FilterState()
        state.toggle(tag: "Beach")
        #expect(state.selectedTags == ["Beach"])
        // Toggling the same tag (differing only in case) removes it — `TagParser.sameTag`.
        state.toggle(tag: "beach")
        #expect(state.selectedTags.isEmpty)
    }

    @Test func toggleTagClearsAnActiveServiceFilter() {
        var state = FilterState(selectedTags: [], filterMode: .and, serviceFilter: .untagged)
        state.toggle(tag: "a")
        #expect(state.serviceFilter == nil)
        #expect(state.selectedTags == ["a"])
    }

    @Test func toggleServiceIsMutuallyExclusiveWithItself() {
        var state = FilterState()
        state.toggle(service: .untagged)
        #expect(state.serviceFilter == .untagged)
        state.toggle(service: .untagged)   // the same triage filter turns off
        #expect(state.serviceFilter == nil)
    }

    @Test func toggleServiceSwitchesBetweenTriageFilters() {
        var state = FilterState()
        state.toggle(service: .untagged)
        state.toggle(service: .skipped)
        #expect(state.serviceFilter == .skipped)
    }

    @Test func setOnlyReplacesTheFilterWithASingleTagAndClearsTriage() {
        var state = FilterState(selectedTags: ["a", "b"], filterMode: .or, serviceFilter: .skipped)
        state.setOnly(tag: "beach")
        #expect(state.selectedTags == ["beach"])
        #expect(state.serviceFilter == nil)
        #expect(state.filterMode == .or)   // the AND/OR operator is left untouched
    }

    @Test func clearTagsLeavesTheTriageFilterInPlace() {
        var state = FilterState(selectedTags: ["a", "b"], filterMode: .and, serviceFilter: .skipped)
        state.clearTags()
        #expect(state.selectedTags.isEmpty)
        #expect(state.serviceFilter == .skipped)
    }

    // MARK: - Persistence (the embedded JSON blob)

    @Test func filterStateRoundTripsANegativeMode() throws {
        let state = FilterState(selectedTags: ["a", "b"], filterMode: .notAll)
        let decoded = try JSONDecoder().decode(FilterState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.filterMode == .notAll)
    }

    @Test func filterStateDecodesLegacyBlobWithoutServiceFilter() throws {
        // A blob written before triage filters (no serviceFilter key) with a legacy mode string
        // still decodes — the new enum cases only add values, they don't disturb the old ones.
        let json = Data(#"{"selectedTags":["beach"],"filterMode":"or"}"#.utf8)
        let decoded = try JSONDecoder().decode(FilterState.self, from: json)
        #expect(decoded.selectedTags == ["beach"])
        #expect(decoded.filterMode == .or)
        #expect(decoded.serviceFilter == nil)
    }

    // MARK: - Mode helpers

    @Test func savedSearchMatchDistinguishesModeAcrossNegatives() {
        let and = SavedSearch(tags: ["a", "b"], mode: .and)
        // Same tag set under a different mode is a different saved search.
        #expect(!and.matches(SavedSearch(tags: ["a", "b"], mode: .notAll)))
        // Same mode + same set (order-insensitive) still matches.
        #expect(and.matches(SavedSearch(tags: ["b", "a"], mode: .and)))
    }

    @Test func savedSearchLabelReadsForEveryMode() {
        #expect(FilterMode.and.savedSearchLabel(["a", "b"]) == "a  +  b")
        #expect(FilterMode.or.savedSearchLabel(["a", "b"]) == "a  /  b")
        #expect(FilterMode.notAll.savedSearchLabel(["a", "b"]) == "not(a  +  b)")
        #expect(FilterMode.notAny.savedSearchLabel(["a", "b"]) == "not(a  /  b)")
    }
}
