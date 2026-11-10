//
//  ScopedFolderAccess.swift
//  ShuTaPla
//
//  The app's security-scoped folder access, in two lifecycles over one `BookmarkService`.
//
//  Playback sessions: each active playlist holds one open, id-keyed, reference-counted
//  session to its folder (`begin`/`end`/`url(for:)`/`releaseAll`) so several playlists on
//  one folder share a single grant, released when the last stops.
//
//  One-shot editing access (`withAccess`): a single file mutation opens its own transient
//  session — never the keyed map — so it can run safely alongside a live playback session
//  (`BookmarkService` reference-counts the grant).
//
//  Every opener refreshes a stale bookmark (the folder moved or was renamed) and the playlist's
//  folder path as it opens the folder, and reports the refresh through `onBookmarkRefresh` so the
//  owner saves it.
//

import Foundation

@MainActor
final class ScopedFolderAccess {

    private let bookmarkService: BookmarkService

    /// Open folder URL per active playlist: the key `startAccess` opened the session under, so the
    /// release ends that session even after the folder was renamed.
    private var folderURLByPlaylist: [UUID: URL] = [:]

    /// Runs after an opener writes a refreshed bookmark or folder path to a playlist.
    var onBookmarkRefresh: () -> Void = {}

    init(bookmarkService: BookmarkService) {
        self.bookmarkService = bookmarkService
    }

    /// Opens a session for `playlist`'s folder and takes a refreshed bookmark and the folder's current
    /// path, or returns `nil` when the bookmark can't be resolved. The path is compared on every open:
    /// a stale bookmark whose re-creation fails still opens the moved folder.
    private func startAccess(for playlist: Playlist) -> URL? {
        guard let access = try? bookmarkService.startAccess(to: playlist.folderBookmark) else { return nil }
        let path = access.url.path(percentEncoded: false)
        let pathChanged = playlist.folderPath != path
        guard access.refreshed != nil || pathChanged else { return access.url }
        if let refreshed = access.refreshed { playlist.folderBookmark = refreshed }
        if pathChanged { playlist.folderPath = path }
        onBookmarkRefresh()
        return access.url
    }

    // MARK: - Playback sessions (id-keyed, reference-counted)

    /// The open folder URL for a playlist, or `nil` when it holds no session.
    func url(for playlistID: UUID) -> URL? { folderURLByPlaylist[playlistID] }

    /// Opens (or reuses) a scoped-access session for `playlist`'s folder, returning its
    /// URL, or `nil` when the bookmark can't be resolved.
    @discardableResult
    func begin(for playlist: Playlist) -> URL? {
        if let url = folderURLByPlaylist[playlist.id] { return url }
        guard let url = startAccess(for: playlist) else { return nil }
        folderURLByPlaylist[playlist.id] = url
        return url
    }

    /// Releases `playlist`'s session; a no-op when it holds none.
    func end(for playlistID: UUID) {
        guard let url = folderURLByPlaylist.removeValue(forKey: playlistID) else { return }
        bookmarkService.stopAccess(to: url)
    }

    /// Releases every open session.
    func releaseAll() {
        for url in folderURLByPlaylist.values { bookmarkService.stopAccess(to: url) }
        folderURLByPlaylist.removeAll()
    }

    // MARK: - Surface browse sessions

    /// Opens a scoped-access session held for as long as a *file surface* (the Manager browser, an
    /// overlay's list) shows `playlist`'s folder, returning the resolved folder URL — so the surface's
    /// per-file thumbnail/metadata reads append to this one URL instead of resolving the bookmark per
    /// file. Independent of the id-keyed playback map: it forwards straight to `BookmarkService`, whose
    /// per-folder reference count lets overlapping surfaces and a playback session on one folder each
    /// hold a ref, released only when the last stops. Returns `nil` (no fast path; the cells resolve
    /// per file) when the bookmark can't be resolved. A caller
    /// balances a non-`nil` result with exactly one `endBrowsing`.
    func beginBrowsing(_ playlist: Playlist) -> URL? {
        startAccess(for: playlist)
    }

    /// Releases a browse session opened by `beginBrowsing`. Takes the URL `beginBrowsing` returned so
    /// the exact grant it acquired is dropped — even if the playlist's bookmark was refreshed to a
    /// relocated folder while the surface stayed open (re-resolving the live bookmark would miss it).
    func endBrowsing(_ url: URL) {
        bookmarkService.stopAccess(to: url)
    }

    // MARK: - One-shot editing access

    /// Runs `body` under a transient scoped session for `playlist`'s folder — its own
    /// `startAccess`/`stopAccess`, independent of any playback session on the same folder.
    /// Returns `nil` when the bookmark can't be resolved.
    func withAccess<T>(to playlist: Playlist, perform body: (URL) -> T) -> T? {
        guard let url = startAccess(for: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: url) }
        return body(url)
    }

    /// The `async` form of `withAccess(to:perform:)`, for bodies that await disk I/O.
    func withAccess<T>(to playlist: Playlist, perform body: (URL) async -> T) async -> T? {
        guard let url = startAccess(for: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: url) }
        return await body(url)
    }
}
