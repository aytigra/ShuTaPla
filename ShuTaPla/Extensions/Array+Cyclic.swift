//
//  Array+Cyclic.swift
//  ShuTaPla
//
//  Wrap-around neighbor lookup, the motion playback uses to step through a
//  sequence: advancing past the last element returns to the first, stepping back
//  from the first returns to the last. Extracted here so the coordinator and its
//  test double share one definition rather than each re-deriving the index math.
//

import Foundation

extension Array {
    /// The element after the first one satisfying `isCurrent`, wrapping past the
    /// end back to the start. When nothing matches, returns `first` — a natural
    /// "start from the beginning". `nil` only when the array is empty.
    func cyclicSuccessor(where isCurrent: (Element) throws -> Bool) rethrows -> Element? {
        guard !isEmpty else { return nil }
        guard let index = try firstIndex(where: isCurrent) else { return first }
        return self[(index + 1) % count]
    }

    /// The element before the first one satisfying `isCurrent`, wrapping from the
    /// start back to the end. When nothing matches, returns `last`. `nil` only when
    /// the array is empty.
    func cyclicPredecessor(where isCurrent: (Element) throws -> Bool) rethrows -> Element? {
        guard !isEmpty else { return nil }
        guard let index = try firstIndex(where: isCurrent) else { return last }
        return self[(index - 1 + count) % count]
    }
}
