//
//  CloudDownloadingPlaceholder.swift
//  ShuTaPla
//
//  The card shown over a black stage while a file's bytes are still downloading from iCloud —
//  a cloud glyph, the filename, and a spinner. Shared by the Player (full-stage) and the Manager
//  preview (inside its card); each caller frames it. The glyph tracks the file's live `cloudStatus`
//  (`icloud` → `icloud.and.arrow.down` once fetching starts).
//

import SwiftUI

struct CloudDownloadingPlaceholder: View {
    let file: PlaylistFile

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: file.cloudStatus.badgeSymbol ?? "icloud.and.arrow.down")
                    .font(.system(size: 48))
                Text(file.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView()
                    .controlSize(.small)
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding()
        }
    }
}
