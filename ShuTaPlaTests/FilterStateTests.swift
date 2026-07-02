//
//  FilterStateTests.swift
//  ShuTaPlaTests
//
//  The pure tag/triage-filter transitions on `FilterState` — a `nonisolated` value type, so these
//  need no main actor or model context.
//

import Testing
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
}
