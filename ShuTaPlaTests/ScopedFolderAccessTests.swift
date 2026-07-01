//
//  ScopedFolderAccessTests.swift
//  ShuTaPlaTests
//
//  The coordinator's per-playlist folder sessions, over a real `BookmarkService`.
//  Playlists are built without a `ModelContext` — only `id`/`folderBookmark` are
//  read — so no SwiftData teardown trap applies.
//

import Testing
import Foundation
@testable import ShuTaPla

@MainActor
struct ScopedFolderAccessTests {

    /// A temp directory and a plain (non-scoped, test) bookmark to it.
    private func makeFolder() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaScopedAccess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    private func makePlaylist(_ bookmark: Data) -> Playlist {
        Playlist(name: "p", folderBookmark: bookmark, folderPath: "/tmp", mediaType: .video)
    }

    @Test func beginOpensSessionAndUrlResolves() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark)

        let url = access.begin(for: playlist)
        #expect(url == folder.url)
        #expect(access.url(for: playlist.id) == folder.url)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 1)
    }

    @Test func beginIsIdempotentForOnePlaylist() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark)

        access.begin(for: playlist)
        access.begin(for: playlist)   // reuses the open session, no second grant
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 1)
    }

    @Test func endReleasesTheSession() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark)

        access.begin(for: playlist)
        access.end(for: playlist.id)
        #expect(access.url(for: playlist.id) == nil)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 0)
    }

    @Test func twoPlaylistsShareOneGrant() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let a = makePlaylist(folder.bookmark)
        let b = makePlaylist(folder.bookmark)

        access.begin(for: a)
        access.begin(for: b)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 2)

        access.end(for: a.id)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 1)   // still open for b
        #expect(access.url(for: b.id) == folder.url)
    }

    @Test func releaseAllClosesEverySession() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let first = try makeFolder()
        let second = try makeFolder()
        access.begin(for: makePlaylist(first.bookmark))
        access.begin(for: makePlaylist(second.bookmark))

        access.releaseAll()
        #expect(bookmarks.referenceCount(for: first.bookmark) == 0)
        #expect(bookmarks.referenceCount(for: second.bookmark) == 0)
    }

    @Test func unresolvableBookmarkYieldsNoSession() {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let playlist = makePlaylist(Data([0x01, 0x02, 0x03]))

        #expect(access.begin(for: playlist) == nil)
        #expect(access.url(for: playlist.id) == nil)
    }
}
