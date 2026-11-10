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

    /// A temp directory and a bookmark to it.
    private func makeFolder() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaScopedAccess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    private func makePlaylist(_ bookmark: Data, folderPath: String = "/tmp") -> Playlist {
        Playlist(name: "p", folderBookmark: bookmark, folderPath: folderPath, mediaType: .video)
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

    /// The folder is renamed while a session is open, and another op opens a session at the new
    /// path. Ending the first session leaves the other op's session open.
    @Test func endAfterAFolderRenameLeavesASessionAtTheNewPath() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let renamed = try renamedLocation(of: folder.url)
        defer { try? FileManager.default.removeItem(at: renamed) }
        let playlist = makePlaylist(folder.bookmark)

        access.begin(for: playlist)
        let other = try openSessionAfterRenaming(folder.url, to: renamed, bookmarks)
        access.end(for: playlist.id)

        #expect(bookmarks.referenceCount(for: other) == 1)
    }

    /// A free location beside `url` for a rename.
    private func renamedLocation(of url: URL) throws -> URL {
        url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent)-renamed")
    }

    /// Renames `url` to `renamed` and opens a session there, as a second op does. Returns that
    /// session's bookmark.
    private func openSessionAfterRenaming(_ url: URL, to renamed: URL, _ bookmarks: BookmarkService) throws -> Data {
        try FileManager.default.moveItem(at: url, to: renamed)
        let bookmark = try BookmarkService.makeBookmark(for: renamed)
        _ = try bookmarks.startAccess(to: bookmark)
        return bookmark
    }

    /// The three ways to open a playlist's folder.
    @MainActor enum Opener: CaseIterable {
        case playback, browsing, oneShot

        func open(_ playlist: Playlist, with access: ScopedFolderAccess) -> URL? {
            switch self {
            case .playback: access.begin(for: playlist)
            case .browsing: access.beginBrowsing(playlist)
            case .oneShot: access.withAccess(to: playlist) { $0 }
            }
        }
    }

    /// A renamed folder opens at its new path, and the playlist takes a bookmark that resolves there
    /// without being stale, reported once for the owner to save.
    @Test(arguments: Opener.allCases)
    func openingARenamedFolderRefreshesTheBookmark(opener: Opener) throws {
        let access = ScopedFolderAccess(bookmarkService: BookmarkService())
        var refreshes = 0
        access.onBookmarkRefresh = { refreshes += 1 }
        let folder = try makeFolder()
        let renamed = try renamedLocation(of: folder.url)
        defer { try? FileManager.default.removeItem(at: renamed) }
        let playlist = makePlaylist(folder.bookmark)
        try FileManager.default.moveItem(at: folder.url, to: renamed)

        let url = try #require(opener.open(playlist, with: access))

        #expect(url.standardizedFileURL == renamed.standardizedFileURL)
        let resolved = try BookmarkService.resolve(playlist.folderBookmark)
        #expect(resolved.url.standardizedFileURL == renamed.standardizedFileURL)
        #expect(!resolved.isStale)
        #expect(playlist.folderPath == url.path(percentEncoded: false))
        #expect(refreshes == 1)
    }

    /// A current bookmark whose stored path names another location opens with the path corrected,
    /// reported once for the owner to save.
    @Test(arguments: Opener.allCases)
    func openingAFolderWithAStalePathCorrectsThePath(opener: Opener) throws {
        let access = ScopedFolderAccess(bookmarkService: BookmarkService())
        var refreshes = 0
        access.onBookmarkRefresh = { refreshes += 1 }
        let folder = try makeFolder()
        let playlist = makePlaylist(folder.bookmark, folderPath: "/old/location/")

        let url = try #require(opener.open(playlist, with: access))

        #expect(playlist.folderPath == url.path(percentEncoded: false))
        #expect(playlist.folderBookmark == folder.bookmark)
        #expect(refreshes == 1)
    }

    /// A current bookmark and path open with no refresh.
    @Test(arguments: Opener.allCases)
    func openingAFolderWithACurrentBookmarkRefreshesNothing(opener: Opener) throws {
        let access = ScopedFolderAccess(bookmarkService: BookmarkService())
        var refreshes = 0
        access.onBookmarkRefresh = { refreshes += 1 }
        let folder = try makeFolder()
        let path = folder.url.path(percentEncoded: false)
        let playlist = makePlaylist(folder.bookmark, folderPath: path)

        #expect(opener.open(playlist, with: access) != nil)

        #expect(playlist.folderBookmark == folder.bookmark)
        #expect(playlist.folderPath == path)
        #expect(refreshes == 0)
    }

    /// A folder in the Trash does not open, and the playlist keeps the bookmark and path it had, so
    /// the folder opens again after Put Back.
    @Test(arguments: Opener.allCases)
    func aFolderInTheTrashDoesNotOpen(opener: Opener) throws {
        let access = ScopedFolderAccess(bookmarkService: BookmarkService())
        var refreshes = 0
        access.onBookmarkRefresh = { refreshes += 1 }
        let folder = try makeFolder()
        let path = folder.url.path(percentEncoded: false)
        let playlist = makePlaylist(folder.bookmark, folderPath: path)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: &trashed)
        let trashedURL = try #require(trashed as URL?)
        defer { try? FileManager.default.removeItem(at: trashedURL) }

        #expect(opener.open(playlist, with: access) == nil)

        #expect(playlist.folderBookmark == folder.bookmark)
        #expect(playlist.folderPath == path)
        #expect(refreshes == 0)

        try FileManager.default.moveItem(at: trashedURL, to: folder.url)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        #expect(opener.open(playlist, with: access) == folder.url)
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

    /// The folder is renamed while the body runs, and another op opens a session at the new path.
    /// The end of the body leaves that session open.
    @Test func withAccessAfterAFolderRenameLeavesASessionAtTheNewPath() throws {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let folder = try makeFolder()
        let renamed = try renamedLocation(of: folder.url)
        defer { try? FileManager.default.removeItem(at: renamed) }
        let playlist = makePlaylist(folder.bookmark)

        let other = try #require(access.withAccess(to: playlist) { _ in
            try? openSessionAfterRenaming(folder.url, to: renamed, bookmarks)
        } ?? nil)
        #expect(bookmarks.referenceCount(for: other) == 1)
    }

    @Test func withAccessUnresolvableBookmarkSkipsTheBody() {
        let bookmarks = BookmarkService()
        let access = ScopedFolderAccess(bookmarkService: bookmarks)
        let playlist = makePlaylist(Data([0x01, 0x02, 0x03]))

        let result = access.withAccess(to: playlist) { _ in "ran" }
        #expect(result == nil)
    }
}
