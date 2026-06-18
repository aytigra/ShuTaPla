//
//  FileCollectionLayoutTests.swift
//  ShuTaPlaTests
//
//  The gallery's adaptive column count drives 2D keyboard navigation, so it must
//  match the packing `LazyVGrid` actually lays out (min item width 150, spacing 12,
//  outer padding one spacing on each side). A degenerate width floors at one column.
//

import Testing
import CoreGraphics
@testable import ShuTaPla

@Suite struct FileCollectionLayoutTests {

    @Test(arguments: [
        (CGFloat(0), 1),     // no room → one column
        (CGFloat(10), 1),    // narrower than the padding → one column
        (CGFloat(200), 1),
        (CGFloat(500), 3),
        (CGFloat(800), 4),
        (CGFloat(1000), 6),
    ])
    func galleryColumnCount(_ width: CGFloat, _ expected: Int) {
        #expect(FileCollectionLayout.galleryColumnCount(for: width) == expected)
    }
}
