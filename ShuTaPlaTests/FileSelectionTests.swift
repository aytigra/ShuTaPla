//
//  FileSelectionTests.swift
//  ShuTaPlaTests
//
//  The click-selection helpers shared by the Manager list/gallery and the player
//  overlay. `apply` is the click itself — plain selects, cmd toggles, shift extends
//  from the anchor — and `actionTargets` decides what a context-menu action (Delete,
//  Remove Audio) operates on: the whole multi-selection when the clicked file is part
//  of it, otherwise just that one file.
//
//  The `actionTargets` cases never insert their models, so only the stable `id` is read
//  — no fetch, no SwiftData trap. `apply` addresses files by `PersistentIdentifier`, so
//  those cases insert into an in-memory container the test body holds alive.
//

import Testing
import Foundation
import AppKit
import SwiftData
@testable import ShuTaPla

@Suite @MainActor struct FileSelectionTests {

    private func file(_ name: String) -> PlaylistFile {
        PlaylistFile(relativePath: name, fileName: name)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Three inserted files plus the identifier sequence a surface would show them in.
    private func inserted(_ context: ModelContext) -> (files: [PlaylistFile], ids: [PersistentIdentifier]) {
        let files = ["a", "b", "c"].map { name -> PlaylistFile in
            let file = file(name)
            context.insert(file)
            return file
        }
        return (files, files.map(\.persistentModelID))
    }

    // MARK: - The click

    @Test func plainClickReplacesTheSelectionAndMovesTheAnchor() throws {
        let container = try makeContainer()
        let (files, ids) = inserted(container.mainContext)
        var selection: Set<UUID> = [files[0].id, files[2].id]
        var anchor: PersistentIdentifier? = ids[0]

        FileSelection.apply(
            click: files[1], modifiers: [], ids: ids,
            uuid: { _ in nil }, selection: &selection, anchor: &anchor
        )
        #expect(selection == [files[1].id])
        #expect(anchor == ids[1])
    }

    @Test func commandClickTogglesOneFileWithoutDisturbingTheRest() throws {
        let container = try makeContainer()
        let (files, ids) = inserted(container.mainContext)
        var selection: Set<UUID> = [files[0].id]
        var anchor: PersistentIdentifier? = ids[0]

        FileSelection.apply(
            click: files[2], modifiers: .command, ids: ids,
            uuid: { _ in nil }, selection: &selection, anchor: &anchor
        )
        #expect(selection == [files[0].id, files[2].id])
        #expect(anchor == ids[2])          // the added file becomes the anchor

        FileSelection.apply(
            click: files[2], modifiers: .command, ids: ids,
            uuid: { _ in nil }, selection: &selection, anchor: &anchor
        )
        #expect(selection == [files[0].id])
        #expect(anchor == ids[2])          // deselecting leaves the anchor where it was
    }

    @Test func shiftClickUnionsTheSpanFromTheAnchorInEitherDirection() throws {
        let container = try makeContainer()
        let (files, ids) = inserted(container.mainContext)
        let uuid: (PersistentIdentifier) -> UUID? = { pid in
            files.first { $0.persistentModelID == pid }?.id
        }
        var selection: Set<UUID> = [files[0].id]
        var anchor: PersistentIdentifier? = ids[0]

        FileSelection.apply(
            click: files[2], modifiers: .shift, ids: ids,
            uuid: uuid, selection: &selection, anchor: &anchor
        )
        #expect(selection == Set(files.map(\.id)))

        // Backwards from an anchor at the end spans the same range.
        selection = [files[2].id]
        anchor = ids[2]
        FileSelection.apply(
            click: files[0], modifiers: .shift, ids: ids,
            uuid: uuid, selection: &selection, anchor: &anchor
        )
        #expect(selection == Set(files.map(\.id)))
        #expect(anchor == ids[2])          // an extend keeps its anchor to extend from again
    }

    @Test func shiftClickWithNoAnchorSelectsJustTheClickedFile() throws {
        let container = try makeContainer()
        let (files, ids) = inserted(container.mainContext)
        var selection: Set<UUID> = [files[0].id]
        var anchor: PersistentIdentifier?

        FileSelection.apply(
            click: files[2], modifiers: .shift, ids: ids,
            uuid: { _ in nil }, selection: &selection, anchor: &anchor
        )
        #expect(selection == [files[2].id])
        #expect(anchor == ids[2])
    }

    // MARK: - What an action targets

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
