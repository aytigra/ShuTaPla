//
//  Array+Move.swift
//  ShuTaPla
//
//  Reordering helper matching SwiftUI's `onMove` semantics, available to the
//  state layer without importing SwiftUI.
//

import Foundation

extension Array {
    /// Moves the elements at `source` so they land just before `destination`,
    /// where `destination` is an offset into the pre-move array (the same index
    /// SwiftUI hands an `.onMove` closure).
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var moved: [Element] = []
        moved.reserveCapacity(source.count)
        for index in source {
            moved.append(self[index])
        }
        for index in source.reversed() {
            remove(at: index)
        }
        let insertAt = destination - source.count(in: 0..<destination)
        insert(contentsOf: moved, at: insertAt)
    }
}
