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
        let moved = source.sorted().map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        let insertAt = destination - source.filter { $0 < destination }.count
        insert(contentsOf: moved, at: insertAt)
    }
}
