//
//  IntPluralizedTests.swift
//  ShuTaPlaTests
//
//  `Int.pluralized` picks singular vs. plural phrasing and must not evaluate the
//  singular branch for a non-1 count (it often indexes a single-element collection).
//

import Testing
@testable import ShuTaPla

@Suite struct IntPluralizedTests {

    @Test func oneUsesSingular() {
        #expect(1.pluralized(one: "1 file", many: "many files") == "1 file")
    }

    @Test func zeroAndManyUsePlural() {
        #expect(0.pluralized(one: "one", many: "0 files") == "0 files")
        #expect(5.pluralized(one: "one", many: "5 files") == "5 files")
    }

    @Test func singularBranchIsNotEvaluatedForPluralCount() {
        // The singular autoclosure would trap (indexing an empty array); a correct
        // implementation never evaluates it when the count isn't 1.
        let empty: [String] = []
        let title = empty.count.pluralized(one: empty[0], many: "no files")
        #expect(title == "no files")
    }
}
