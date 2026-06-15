//
//  TagTokenFieldTests.swift
//  ShuTaPlaTests
//
//  Task 14.2 — the pure suggestion ranking behind `TagTokenField`, shared by the tag
//  editor and the filter. `options(query:knownTags:selected:allowsCreate:)` excludes
//  the already-selected tags, ranks matches against the typed string (exact, then
//  prefix, then substring) ahead of frequency, and — only when create is allowed —
//  trails a `.create` row for a valid, unused, typed tag.
//

import Testing
import SwiftUI
@testable import ShuTaPla

@MainActor
struct TagTokenFieldTests {
    private let known = ["city": 10, "cinema": 3, "musician": 7, "beach": 8, "forest": 1]

    private func tags(_ options: [TagOption]) -> [String] {
        options.map(\.tag)
    }

    @Test func emptyQueryRanksByFrequency() {
        let options = TagTokenField<EmptyView>.options(
            query: "", knownTags: known, selected: [], allowsCreate: false
        )
        #expect(tags(options) == ["city", "beach", "musician", "cinema", "forest"])
    }

    @Test func prefixMatchesOutrankSubstringMatches() {
        // "ci" prefixes city/cinema; it only appears mid-word in "musician" — which
        // outranks "cinema" on frequency but still sorts below both prefix matches.
        let options = TagTokenField<EmptyView>.options(
            query: "ci", knownTags: known, selected: [], allowsCreate: false
        )
        #expect(tags(options) == ["city", "cinema", "musician"])
    }

    @Test func selectedTagsAreExcluded() {
        let options = TagTokenField<EmptyView>.options(
            query: "", knownTags: known, selected: ["city", "beach"], allowsCreate: false
        )
        #expect(!tags(options).contains("city"))
        #expect(!tags(options).contains("beach"))
    }

    @Test func matchingIsCaseInsensitive() {
        let options = TagTokenField<EmptyView>.options(
            query: "CITY", knownTags: known, selected: [], allowsCreate: false
        )
        #expect(tags(options) == ["city"])
    }

    @Test func createRowTrailsAValidNewTagWhenAllowed() {
        let options = TagTokenField<EmptyView>.options(
            query: "sunset", knownTags: known, selected: [], allowsCreate: true
        )
        #expect(options.last == .create("sunset"))
    }

    @Test func noCreateRowWhenCreateDisallowed() {
        let options = TagTokenField<EmptyView>.options(
            query: "sunset", knownTags: known, selected: [], allowsCreate: false
        )
        #expect(options.isEmpty)
    }

    @Test func noCreateRowForInvalidTag() {
        // Below the three-character minimum, so not a valid tag to create.
        let options = TagTokenField<EmptyView>.options(
            query: "ab", knownTags: known, selected: [], allowsCreate: true
        )
        #expect(!options.contains { if case .create = $0 { return true } else { return false } })
    }

    @Test func noCreateRowWhenTagAlreadyExists() {
        let options = TagTokenField<EmptyView>.options(
            query: "city", knownTags: known, selected: [], allowsCreate: true
        )
        #expect(!options.contains { if case .create = $0 { return true } else { return false } })
        #expect(tags(options) == ["city"])
    }

    @Test func noCreateRowWhenTagAlreadySelected() {
        let options = TagTokenField<EmptyView>.options(
            query: "city", knownTags: known, selected: ["city"], allowsCreate: true
        )
        #expect(options.isEmpty)
    }
}
