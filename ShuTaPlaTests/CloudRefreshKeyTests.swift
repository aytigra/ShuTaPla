//
//  CloudRefreshKeyTests.swift
//  ShuTaPlaTests
//
//  The `.task(id:)` keys that drive cloud-aware refresh: when a file's bytes arrive and its
//  `cloudStatus` flips to `.local`, the gallery tile regenerates its thumbnail and the list row
//  re-extracts its metadata. Each surface folds the file's local-ness into its task id so the flip
//  re-fires generation — these tests pin that the key actually changes across the boundary.
//

import Testing
import SwiftUI
@testable import ShuTaPla

@MainActor @Suite struct CloudRefreshKeyTests {

    private func makeFile() -> (Playlist, PlaylistFile) {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        let file = PlaylistFile(relativePath: "a.png", fileName: "a.png")
        return (playlist, file)
    }

    @Test func galleryThumbnailKeyChangesWhenFileBecomesLocal() {
        let (playlist, file) = makeFile()
        let cell = GalleryCell(
            file: file, playlist: playlist, isSelected: false, isCurrent: false,
            isRenaming: false, isStripping: false, draftName: .constant(""),
            onCommitRename: {}, onCancelRename: {}
        )
        file.cloudStatus = .inCloud
        let evicted = cell.thumbnailKey
        file.cloudStatus = .local
        #expect(cell.thumbnailKey != evicted)   // the flip to local re-fires the thumbnail task
    }

    @Test func listMetadataKeyChangesWhenFileBecomesLocal() {
        let (playlist, file) = makeFile()
        let row = FileRowView(
            file: file, playlist: playlist, isSelected: false, isCurrent: false,
            isRenaming: false, isStripping: false, draftName: .constant(""),
            onCommitRename: {}, onCancelRename: {}
        )
        file.cloudStatus = .inCloud
        let evicted = row.metadataKey
        file.cloudStatus = .local
        #expect(row.metadataKey != evicted)     // the flip to local re-fires the metadata task
    }
}
