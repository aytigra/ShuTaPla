//
//  DictionaryCountTests.swift
//  ShuTaPlaTests
//

import Testing
@testable import ShuTaPla

@Suite struct DictionaryCountTests {

  @Test func decrementKeepsAPositiveCount() {
    var counts = ["a": 2]
    #expect(counts.decrementCount(forKey: "a") == 1)
    #expect(counts == ["a": 1])
  }

  @Test func decrementToZeroRemovesTheKey() {
    var counts = ["a": 1, "b": 3]
    #expect(counts.decrementCount(forKey: "a") == 0)
    #expect(counts == ["b": 3])
  }

  @Test func decrementOfAMissingKeyLeavesNoKey() {
    var counts = ["b": 3]
    #expect(counts.decrementCount(forKey: "a") == 0)
    #expect(counts == ["b": 3])
  }
}
