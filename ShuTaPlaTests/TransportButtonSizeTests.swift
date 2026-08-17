//
//  TransportButtonSizeTests.swift
//  ShuTaPlaTests
//
//  The pure seam of the shared transport button: how each size lays its glyph out. The
//  player surfaces exist to be watched, so a control that changes symbol under the pointer
//  (play↔pause, expand↔collapse) must not move the ones beside it.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct TransportButtonSizeTests {

    @Test func thePlayerSurfacesShareOneGlyphCell() {
        #expect(TransportButton.Size.bar.glyphFrame == TransportButton.Size.chrome.glyphFrame)
        #expect(TransportButton.Size.bar.glyphFrame != nil)
    }

    /// A fixed cell is what keeps a symbol swap from shifting the row, so it must be at least as
    /// wide as it is tall — the widest transport glyphs are wider than they are high.
    @Test func theGlyphCellIsWiderThanItIsTall() throws {
        let cell = try #require(TransportButton.Size.bar.glyphFrame)
        #expect(cell.width > cell.height)
    }

    /// The inlet sits inside a text row, so it pins neither font nor size and inherits both.
    @Test func theInlineSizeImposesNothing() {
        #expect(TransportButton.Size.inline.glyphFrame == nil)
        #expect(TransportButton.Size.inline.font == nil)
    }

    @Test func bothPlayerSurfacesSetTheirOwnFont() {
        #expect(TransportButton.Size.bar.font != nil)
        #expect(TransportButton.Size.chrome.font != nil)
        #expect(TransportButton.Size.bar.font != TransportButton.Size.chrome.font)
    }
}
