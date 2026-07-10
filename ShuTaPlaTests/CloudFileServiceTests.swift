//
//  CloudFileServiceTests.swift
//  ShuTaPlaTests
//
//  The live-feed apply core of `CloudFileService`: given normalized status updates
//  keyed by relative path, it flips `cloudStatus` on the matching model and leaves
//  every other file untouched. Driven directly through the update seam, so no live
//  `NSMetadataQuery` or iCloud account is involved.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct CloudFileServiceTests {

    /// A fresh in-memory container with the full app schema, held for the whole test body
    /// so its `mainContext` never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self,
            AppStateModel.self, GlobalSettings.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeFile(_ path: String, in context: ModelContext) -> PlaylistFile {
        let file = PlaylistFile(relativePath: path, fileName: path)
        context.insert(file)
        return file
    }

    @Test func applyFlipsMatchingFileAndLeavesOthers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)
        let b = makeFile("sub/b.mp4", in: context)
        let c = makeFile("c.mp4", in: context)

        let service = CloudFileService()
        service.apply(
            [
                CloudStatusUpdate(relativePath: "a.mp4", status: .inCloud),
                CloudStatusUpdate(relativePath: "sub/b.mp4", status: .downloading),
            ],
            to: [a, b, c]
        )

        #expect(a.cloudStatus == .inCloud)     // matched by path
        #expect(b.cloudStatus == .downloading) // matched, nested path
        #expect(c.cloudStatus == .local)       // unmentioned — untouched
    }

    @Test func applyIgnoresUpdatesWithNoMatchingFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)

        let service = CloudFileService()
        service.apply([CloudStatusUpdate(relativePath: "ghost.mp4", status: .inCloud)], to: [a])

        #expect(a.cloudStatus == .local)   // the one file is left alone
    }

    @Test func applyRewritesStatusOnRepeatUpdates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = makeFile("a.mp4", in: context)

        let service = CloudFileService()
        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .inCloud)], to: [a])
        #expect(a.cloudStatus == .inCloud)

        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .downloading)], to: [a])
        #expect(a.cloudStatus == .downloading)   // a later event supersedes the earlier one

        service.apply([CloudStatusUpdate(relativePath: "a.mp4", status: .local)], to: [a])
        #expect(a.cloudStatus == .local)         // download completed → back to local
    }

    /// A temp directory and a plain (non-scoped, test) bookmark to it — so `requestDownload`
    /// resolves the folder without an iCloud account or a security-scoped grant.
    private func makeFolder() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaCloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    @Test func requestDownloadIssuesOneRequestForTheFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder()
        let playlist = Playlist(
            name: "P", folderBookmark: folder.bookmark, folderPath: "/p", mediaType: .video
        )
        context.insert(playlist)
        let file = makeFile("clip.mp4", in: context)
        file.playlist = playlist

        var requested: [URL] = []
        let service = CloudFileService(requester: { requested.append($0) })
        service.requestDownload(file)

        #expect(requested.count == 1)                              // exactly one request
        #expect(requested.first?.lastPathComponent == "clip.mp4")  // for the named file
    }

    @Test func requestDownloadIsANoOpWhenTheFileHasNoPlaylist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let file = makeFile("orphan.mp4", in: context)

        var requested: [URL] = []
        let service = CloudFileService(requester: { requested.append($0) })
        service.requestDownload(file)

        #expect(requested.isEmpty)   // no folder to resolve → nothing requested
    }
}
