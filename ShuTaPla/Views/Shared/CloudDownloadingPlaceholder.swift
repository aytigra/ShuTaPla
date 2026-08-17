//
//  CloudDownloadingPlaceholder.swift
//  ShuTaPla
//
//  The `StagePlaceholder` shown while a file's bytes are still downloading from iCloud, named
//  because two surfaces raise it — the Player (full-stage) and the Manager preview (inside its
//  card) — and both want the same glyph rule: it tracks the file's live `cloudStatus`
//  (`icloud` → `icloud.and.arrow.down` once fetching starts).
//

import SwiftUI

struct CloudDownloadingPlaceholder: View {
    let file: PlaylistFile

    var body: some View {
        StagePlaceholder(
            file.fileName,
            systemImage: file.cloudStatus.badgeSymbol ?? "icloud.and.arrow.down",
            showsProgress: true
        )
    }
}
