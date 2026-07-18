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
import SwiftData

enum FileSelection {

    /// Applies a click on `file` with the current modifier flags, mutating the selection set
    /// and anchor in place. The list is the ordered identifier sequence (`ids`); a shift-extend
    /// resolves only the spanned range to UUIDs through `uuid`, so plain and cmd clicks resolve
    /// nothing and a range click resolves just its span — the whole list is never materialized.
    /// The anchor is an identifier so it survives re-derivation without holding a model.
    static func apply(
        click file: PlaylistFile,
        modifiers: NSEvent.ModifierFlags,
        ids: [PersistentIdentifier],
        uuid: (PersistentIdentifier) -> UUID?,
        selection: inout Set<UUID>,
        anchor: inout PersistentIdentifier?
    ) {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        let id = file.id
        let pid = file.persistentModelID

        if mods.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
                anchor = pid
            }
        } else if mods.contains(.shift),
                  let anchorPID = anchor,
                  let lo = ids.firstIndex(of: anchorPID),
                  let hi = ids.firstIndex(of: pid) {
            let range = lo <= hi ? lo...hi : hi...lo
            selection.formUnion(ids[range].compactMap(uuid))
        } else {
            selection = [id]
            anchor = pid
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
