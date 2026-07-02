//
//  AppState+Preview.swift
//  ShuTaPla
//
//  The Manager "peek" gate: `[space]` on a single selected video/image file opens the preview
//  lightbox, and `[space]`/`[esc]` closes it. The engine work lives in `MediaPreview`; this is
//  the selection rule that decides whether to open, and the close entry point the router calls.
//

import Foundation

extension AppState {

    /// Toggles the preview from `[space]`. Closes an open preview; otherwise opens it only when
    /// the managed playlist is video/image and the visible selection is exactly one file. Returns
    /// whether it acted, so the key consumes only when it does.
    @discardableResult
    func togglePreviewOfSelection() -> Bool {
        if preview.isOpen { preview.close(); return true }
        guard let playlist = managedPlaylist, playlist.mediaType != .audio else { return false }
        let selected = managerSelectionFiles()
        guard selected.count == 1, let file = selected.first else { return false }
        preview.toggle(file)
        return true
    }

    /// Closes an open preview (the `[esc]` / re-`[space]` terminus). A no-op when none is open.
    func closePreview() {
        preview.close()
    }
}
