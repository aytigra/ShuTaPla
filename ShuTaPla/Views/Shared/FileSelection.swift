//
//  FileSelection.swift
//  ShuTaPla
//
//  The click-selection algorithm shared by the Manager file list and gallery:
//  plain click selects, cmd-click toggles, shift-click extends from the anchor.
//  Both views keep their own selection set and anchor and route clicks here so
//  the behavior stays identical.
//

import AppKit

enum FileSelection {

    /// Applies a click on `id` with the current modifier flags, mutating the
    /// selection set and anchor in place.
    static func apply(
        click id: UUID,
        modifiers: NSEvent.ModifierFlags,
        in files: [PlaylistFile],
        selection: inout Set<UUID>,
        anchor: inout UUID?
    ) {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
                anchor = id
            }
        } else if mods.contains(.shift),
                  let anchorID = anchor,
                  let lo = files.firstIndex(where: { $0.id == anchorID }),
                  let hi = files.firstIndex(where: { $0.id == id }) {
            let range = lo <= hi ? lo...hi : hi...lo
            selection.formUnion(files[range].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    /// The files a context-menu action should target: the whole selection when the
    /// clicked file is part of a multi-selection, otherwise just that file.
    static func actionTargets(
        for file: PlaylistFile,
        selection: Set<UUID>,
        visible: [PlaylistFile]
    ) -> [PlaylistFile] {
        let selected = visible.filter { selection.contains($0.id) }
        return selection.contains(file.id) && selected.count > 1 ? selected : [file]
    }
}
