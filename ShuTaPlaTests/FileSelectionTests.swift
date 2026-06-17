//
//  FileSelectionTests.swift
//  ShuTaPlaTests
//
//  The click-selection helpers shared by the Manager list/gallery and the player
//  overlay. `actionTargets` decides what a context-menu action (Delete, Remove
//  Audio) operates on: the whole multi-selection when the clicked file is part of
//  it, otherwise just that one file. The models are never inserted into a context,
//  so only their stable `id` is read — no fetch, no SwiftData trap.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite @MainActor struct FileSelectionTests {

    private func file(_ name: String) -> PlaylistFile {
        PlaylistFile(relativePath: name, fileName: name)
    }

    @Test func clickedFileOutsideSelectionTargetsOnlyIt() {
        let a = file("a"), b = file("b"), c = file("c")
        let visible = [a, b, c]
        // b and c are selected, but the menu was raised on a.
        let targets = FileSelection.actionTargets(for: a, selection: [b.id, c.id], visible: visible)
        #expect(targets.map(\.id) == [a.id])
    }

    @Test func clickedFileInMultiSelectionTargetsWholeSelection() {
        let a = file("a"), b = file("b"), c = file("c")
        let visible = [a, b, c]
        let targets = FileSelection.actionTargets(for: a, selection: [a.id, c.id], visible: visible)
        // Returned in visible order, not selection order.
        #expect(targets.map(\.id) == [a.id, c.id])
    }

    @Test func soleSelectedFileTargetsOnlyIt() {
        let a = file("a"), b = file("b")
        let visible = [a, b]
        let targets = FileSelection.actionTargets(for: a, selection: [a.id], visible: visible)
        #expect(targets.map(\.id) == [a.id])
    }
}
