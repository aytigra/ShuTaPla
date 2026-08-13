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
//  Plus the two things its dismissal rests on: the panel height the field hands the
//  click monitor as its reach below itself, and AppKit's own handling of a text field
//  that leaves the view hierarchy mid-edit.
//

import Testing
import SwiftUI
import AppKit
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

    // MARK: - Dismissal

    @Test func theDropdownGrowsByTheRowAndStopsAtSix() {
        #expect(TagTokenField<EmptyView>.dropdownHeight(optionCount: 1) == 30)
        #expect(TagTokenField<EmptyView>.dropdownHeight(optionCount: 6) == 180)
        // Past six it scrolls instead of growing, so the monitor's reach stops growing too.
        #expect(TagTokenField<EmptyView>.dropdownHeight(optionCount: 40) == 180)
    }

    @Test func noOptionsIsNoPanelToClick() {
        #expect(TagTokenField<EmptyView>.dropdownHeight(optionCount: 0) == 0)
    }

    @Test func droppingTheEditingFieldHandsFocusBackToTheWindow() {
        // The field gives up focus by ceasing to exist: a click away ends editing, which takes the
        // input out of the hierarchy. Pinned against AppKit itself, since it is AppKit's half of the
        // contract — were a removed field to stay first responder, keys would go on reaching it.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(host)
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 22))
        host.addSubview(field)

        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil, "the field editor is engaged while editing")

        host.removeFromSuperview()

        #expect(window.firstResponder === window)
        #expect(field.currentEditor() == nil)
    }
}
