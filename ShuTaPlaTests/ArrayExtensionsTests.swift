//
//  ArrayExtensionsTests.swift
//  ShuTaPlaTests
//
//  The pure wrap-around stepping behind motion playback (`cyclicSuccessor` /
//  `cyclicPredecessor`): standalone value-type logic, exercised without any model or
//  engine. The reordering helper `move(fromOffsets:toOffset:)` is covered through its
//  production entry point in `AppStateTests.reorderUpdatesSortOrder`.
//

import Testing
import Foundation
@testable import ShuTaPla

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
