//
//  FilterStripTests.swift
//  ShuTaPlaTests
//
//  The strip's two pure seams. The precedence is the one worth pinning: a tag filter and a triage
//  filter can be set at the same time — the model deliberately keeps them independent — so it is the
//  strip alone that decides which of them the user sees, and "each case shows exactly one thing" is
//  a claim about the resolver, not about any view.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct FilterStripModeTests {

    func mode(
        review: Bool = false, service: ServiceFilter? = nil, tagFilter: Bool = false
    ) -> FilterStripMode {
        FilterStripMode.resolve(inReviewMode: review, serviceFilter: service, hasTagFilter: tagFilter)
    }

    // MARK: - The four cases

    @Test func anUnfilteredPlaylistOffersTheFilterControlsAndTheTriageCounts() {
        #expect(mode() == .unfiltered)
    }

    @Test func aSetTagFilterHidesTheTriageCounts() {
        // Not cosmetic: the counts each *set* a triage filter, and doing that from under a tag
        // filter would replace what the strip is showing.
        let filtered = mode(tagFilter: true)
        #expect(filtered == .tagFiltered)
        #expect(filtered.showsFilterControls)
        #expect(filtered.showsClear)
        #expect(!filtered.showsTriageCounts)
    }

    @Test func aTriageFilterShowsAloneEvenWithATagFilterSetUnderneath() {
        // The parked tag filter is hidden, not lost — the model keeps it, and clearing the triage
        // filter drops back to `.tagFiltered`.
        let triaged = mode(service: .untagged, tagFilter: true)
        #expect(triaged == .serviceFiltered(.untagged))
        #expect(!triaged.showsFilterControls)
        #expect(!triaged.showsClear)
        #expect(!triaged.showsTriageCounts)
        #expect(mode(tagFilter: true) == .tagFiltered)
    }

    @Test func aReviewModeOutranksBothFilterKinds() {
        let reviewing = mode(review: true, service: .invalidTagging, tagFilter: true)
        #expect(reviewing == .reviewing)
        #expect(!reviewing.showsFilterControls)
        #expect(!reviewing.showsClear)
        #expect(!reviewing.showsTriageCounts)
    }

    // MARK: - The ordering as a whole

    @Test(arguments: [false, true], [false, true])
    func exactlyOneThingIsEverShown(_ hasService: Bool, _ hasTagFilter: Bool) {
        // Swept over every combination the model can store, including both filters at once: no
        // state shows the filter controls and a triage state together, and none shows nothing.
        for review in [false, true] {
            let resolved = mode(
                review: review, service: hasService ? .untagged : nil, tagFilter: hasTagFilter
            )
            let banner = resolved == .reviewing || resolved == .serviceFiltered(.untagged)
            #expect(banner != resolved.showsFilterControls)
            #expect(!(resolved.showsClear && banner))
            #expect(!(resolved.showsTriageCounts && banner))
        }
    }

    @Test func clearAndTheTriageCountsAreNeverShownTogether() {
        // They are the two halves of "is a tag filter set" — `Clear` acts on one, the counts offer
        // to replace it — so a state showing both would offer to clear a filter and to bypass it.
        for review in [false, true] {
            for service in [nil, ServiceFilter.untagged, .invalidTagging] {
                for tagFilter in [false, true] {
                    let resolved = mode(review: review, service: service, tagFilter: tagFilter)
                    #expect(!(resolved.showsClear && resolved.showsTriageCounts))
                }
            }
        }
    }
}

@Suite struct FilterStripLayoutTests {

    let field = FilterStripLayout.minimumFieldWidth

    @Test func aWideStripPutsTheFourFieldsInOneRow() {
        #expect(FilterStripLayout.columns(forWidth: 4 * field) == 4)
        #expect(FilterStripLayout.columns(forWidth: 2000) == 4)
    }

    @Test func aMediumStripSplitsIntoTwoRowsOfTwo() {
        #expect(FilterStripLayout.columns(forWidth: 2 * field) == 2)
        #expect(FilterStripLayout.columns(forWidth: 4 * field - 1) == 2)
    }

    @Test func aNarrowStripStacksTheFieldsInOneColumn() {
        #expect(FilterStripLayout.columns(forWidth: 2 * field - 1) == 1)
        #expect(FilterStripLayout.columns(forWidth: 0) == 1)
    }

    @Test(arguments: [CGFloat(-500), 0, 1, 100, 439, 440, 441, 879, 880, 881, 1600])
    func everyWidthDividesTheFourFieldsEvenly(_ width: CGFloat) {
        // The count halving is what keeps the grid from leaving a ragged last row — three columns
        // would put one field alone under three.
        let columns = FilterStripLayout.columns(forWidth: width)
        #expect([1, 2, 4].contains(columns))
        #expect(TagFilterField.allCases.count % columns == 0)
    }

    @Test(arguments: [CGFloat(0), 219, 440, 879, 880, 2000])
    func widerIsNeverFewerColumns(_ width: CGFloat) {
        #expect(FilterStripLayout.columns(forWidth: width + 1) >= FilterStripLayout.columns(forWidth: width))
    }
}
