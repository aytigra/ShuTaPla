//
//  ArrayExtensionsTests.swift
//  ShuTaPlaTests
//
//  The pure value-type array helpers: the reordering helper `move(fromOffsets:toOffset:)`
//  matching SwiftUI's `onMove`, and the wrap-around stepping behind motion playback
//  (`cyclicSuccessor` / `cyclicPredecessor`). Standalone logic, exercised without any
//  model or engine.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct ArrayMoveTests {
  
  @Test func movesASingleElementDownward() {
    var items = ["a", "b", "c", "d"]
    items.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
    #expect(items == ["b", "a", "c", "d"])
  }
  
  @Test func movesASingleElementUpward() {
    var items = ["a", "b", "c", "d"]
    items.move(fromOffsets: IndexSet(integer: 3), toOffset: 1)
    #expect(items == ["a", "d", "b", "c"])
  }
  
  @Test func movesMultipleNonContiguousElements() {
    var indices = IndexSet()
    indices.insert(0)
    indices.insert(2)
    var items = [0, 1, 2, 3, 4]
    items.move(fromOffsets: indices, toOffset: 4)
    #expect(items == [1, 3, 0, 2, 4])
  }
  
  @Test func movingToTheEndAppends() {
    var items = ["a", "b", "c"]
    items.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(items == ["b", "c", "a"])
  }
}

@Suite struct ArrayCyclicTests {

    @Test func successorWrapsPastTheLast() {
        let items = [1, 2, 3]
        #expect(items.cyclicSuccessor { $0 == 2 } == 3)
        #expect(items.cyclicSuccessor { $0 == 3 } == 1)   // wraps to the first
    }

    @Test func predecessorWrapsBeforeTheFirst() {
        let items = [1, 2, 3]
        #expect(items.cyclicPredecessor { $0 == 2 } == 1)
        #expect(items.cyclicPredecessor { $0 == 1 } == 3)   // wraps to the last
    }

    @Test func noMatchFallsBackToTheEnds() {
        let items = [1, 2, 3]
        #expect(items.cyclicSuccessor { $0 == 99 } == 1)     // → first
        #expect(items.cyclicPredecessor { $0 == 99 } == 3)   // → last
    }

    @Test func emptyArrayHasNoNeighbor() {
        let items: [Int] = []
        #expect(items.cyclicSuccessor { _ in true } == nil)
        #expect(items.cyclicPredecessor { _ in true } == nil)
    }
}
