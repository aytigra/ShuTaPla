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

    /// A re-access prompt returning a preset URL (or `nil` to model the user cancelling).
    private struct StubReaccess: FolderReaccessPrompting {
        var granted: URL?
        func requestAccess(to playlist: Playlist) -> URL? { granted }
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

    // MARK: - Surface browse sessions

    @Test func beginBrowsingHoldsOneGrantAndResolves() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark)

        let url = try #require(access.beginBrowsing(playlist))
        #expect(url == folder.url)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 1)
        access.endBrowsing(url)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 0)
    }

    // A browse surface and a playback session on one folder each hold an independent reference — the
    // per-folder grant is shared, released only when the last of the two stops. This is why a browse
    // session must forward to `BookmarkService` (reference-counted) rather than the id-keyed map.
    @Test func browseAndPlaybackShareGrantIndependently() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark)

        access.begin(for: playlist)                 // a playback session
        let url = try #require(access.beginBrowsing(playlist))   // plus a browse session on the same folder
        #expect(url == folder.url)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 2)

        access.endBrowsing(url)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 1)   // playback still holds the grant
        #expect(access.url(for: playlist.id) == folder.url)

        access.end(for: playlist.id)
        #expect(bookmarks.referenceCount(for: folder.bookmark) == 0)
    }

    // A folder relocation mid-surface refreshes the playlist's bookmark to a different URL. Ending the
    // browse session must release the grant taken at begin — not re-resolve the now-different live
    // bookmark, find no session, and leak the original grant.
    @Test func endBrowsingReleasesGrantAfterMidSurfaceBookmarkRefresh() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let original = try makeFolder()
        let relocated = try makeFolder()
        let playlist = makePlaylist(original.bookmark)

        let url = try #require(access.beginBrowsing(playlist))
        #expect(bookmarks.referenceCount(for: original.bookmark) == 1)

        // The folder moves; a stale-bookmark refresh repoints the playlist at the new location.
        playlist.folderBookmark = relocated.bookmark

        access.endBrowsing(url)
        #expect(bookmarks.referenceCount(for: original.bookmark) == 0)   // original grant released
        #expect(bookmarks.referenceCount(for: relocated.bookmark) == 0)  // the new location was never opened
    }

    @Test func beginBrowsingUnresolvableBookmarkYieldsNoSession() {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let playlist = makePlaylist(Data([0x01, 0x02, 0x03]))

        #expect(access.beginBrowsing(playlist) == nil)
        #expect(bookmarks.referenceCount(for: playlist.folderBookmark) == 0)
    }

    // MARK: - One-shot editing access

    @Test func withAccessRunsBodyUnderScopedSessionAndReleases() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark)

        let seen = access.withAccess(to: playlist) { $0 }
        #expect(seen == folder.url)
        // The transient session is balanced — no grant leaks past the body.
        #expect(bookmarks.referenceCount(for: playlist.folderBookmark) == 0)
    }

    @Test func withAccessRefreshesStaleBookmarkThroughPrompt() throws {
        let bookmarks = BookmarkService()
        let folder = try makeFolder()
        // A garbage bookmark fails the initial resolve, forcing the re-grant path.
        let access = ScopedFolderAccess(bookmarkService: bookmarks, prompt: StubReaccess(granted: folder.url))
        let playlist = makePlaylist(Data([0x01, 0x02, 0x03]))

        let seen = access.withAccess(to: playlist) { $0 }
        #expect(seen == folder.url)
        // The prompt's folder was baked into a fresh bookmark and path on the playlist.
        #expect(playlist.folderPath == folder.url.path(percentEncoded: false))
        #expect((try? BookmarkService.resolve(playlist.folderBookmark))?.url == folder.url)
        #expect(bookmarks.referenceCount(for: playlist.folderBookmark) == 0)
    }

    @Test func withAccessReturnsNilWhenPromptCancels() {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks, prompt: StubReaccess(granted: nil))
        let playlist = makePlaylist(Data([0x01, 0x02, 0x03]))

        let result = access.withAccess(to: playlist) { _ in "ran" }
        #expect(result == nil)
    }
}
