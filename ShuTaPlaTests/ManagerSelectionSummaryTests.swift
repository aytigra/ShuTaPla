//
//  ManagerSelectionSummaryTests.swift
//  ShuTaPlaTests
//
//  The pure summary line of the Manager multi-selection preview: given the selected count and
//  how many of those fell out of the effective filter, it decides the wording and whether the
//  filtered-out info icon shows.
//

import Testing
@testable import ShuTaPla

struct ManagerSelectionSummaryTests {

    /// None filtered out → a plain count, no icon.
    @Test func noneFilteredOutIsPlainCount() {
        let summary = ManagerSelectionSummary(selectedCount: 3, filteredOutCount: 0)
        #expect(summary.text == "3 selected")
        #expect(summary.showsIcon == false)
    }

    /// Some (but not all) filtered out → the split count with the icon.
    @Test func someFilteredOutShowsBothCounts() {
        let summary = ManagerSelectionSummary(selectedCount: 5, filteredOutCount: 2)
        #expect(summary.text == "5 selected · 2 filtered out")
        #expect(summary.showsIcon == true)
    }

    /// All filtered out → the collapsed "All filtered out" wording (not "N selected · N filtered
    /// out"), with the icon.
    @Test func allFilteredOutCollapsesWording() {
        let summary = ManagerSelectionSummary(selectedCount: 4, filteredOutCount: 4)
        #expect(summary.text == "All filtered out")
        #expect(summary.showsIcon == true)
    }
}
