//
//  Dictionary+Count.swift
//  ShuTaPla
//

extension Dictionary where Value == Int {
    /// Decrements the count under `key` and removes the key once the count reaches zero, so a
    /// present key always holds a positive count. Returns the count left.
    @discardableResult
    nonisolated mutating func decrementCount(forKey key: Key) -> Int {
        let left = self[key, default: 1] - 1
        self[key] = left > 0 ? left : nil
        return left
    }
}
