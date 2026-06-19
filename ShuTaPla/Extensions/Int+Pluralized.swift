//
//  Int+Pluralized.swift
//  ShuTaPla
//
//  Picks singular vs. plural phrasing for a count.
//

import Foundation

extension Int {
    /// Returns `one` when the count is exactly 1, otherwise `many`. Both are
    /// autoclosures so the singular phrasing — which often indexes a single-element
    /// collection — isn't evaluated for a plural (possibly empty) count.
    func pluralized(one: @autoclosure () -> String, many: @autoclosure () -> String) -> String {
        self == 1 ? one() : many()
    }
}
