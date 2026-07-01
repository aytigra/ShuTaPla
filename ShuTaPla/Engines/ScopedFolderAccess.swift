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
//  (`BookmarkService` reference-counts the grant). When the saved bookmark is stale or denied,
//  it prompts (through `FolderReaccessPrompting`) to re-locate the folder and refreshes the
//  bookmark before retrying. Bookmark refreshes mutate the playlist in memory; the caller saves.
//

import Foundation

/// Re-grant seam: asks the user to point at a playlist's folder again when its bookmark is
/// stale, keeping `ScopedFolderAccess` free of any UI framework. Production wires
/// `FolderReaccessPanel`; tests wire a stub.
@MainActor
protocol FolderReaccessPrompting {
    func requestAccess(to playlist: Playlist) -> URL?
}

/// The default when no prompt is wired (tests): access is simply denied on a stale bookmark.
struct DeniedFolderReaccess: FolderReaccessPrompting {
    func requestAccess(to playlist: Playlist) -> URL? { nil }
}

@MainActor
final class ScopedFolderAccess {

    private let bookmarkService: BookmarkService
    private let prompt: FolderReaccessPrompting

    /// Open folder URL per active playlist. The bookmark is kept alongside so the
    /// matching `stopAccess` can be issued on release.
    private var folderURLByPlaylist: [UUID: URL] = [:]
    private var bookmarkByPlaylist: [UUID: Data] = [:]

    init(bookmarkService: BookmarkService, prompt: FolderReaccessPrompting = DeniedFolderReaccess()) {
        self.bookmarkService = bookmarkService
        self.prompt = prompt
    }

    // MARK: - Playback sessions (id-keyed, reference-counted)

    /// The open folder URL for a playlist, or `nil` when it holds no session.
    func url(for playlistID: UUID) -> URL? { folderURLByPlaylist[playlistID] }

    /// Opens (or reuses) a scoped-access session for `playlist`'s folder, returning its
    /// URL, or `nil` when the bookmark can't be resolved.
    @discardableResult
    func begin(for playlist: Playlist) -> URL? {
        if let url = folderURLByPlaylist[playlist.id] { return url }
        guard let url = try? bookmarkService.startAccess(to: playlist.folderBookmark) else { return nil }
        folderURLByPlaylist[playlist.id] = url
        bookmarkByPlaylist[playlist.id] = playlist.folderBookmark
        return url
    }

    /// Releases `playlist`'s session; a no-op when it holds none.
    func end(for playlistID: UUID) {
        guard let bookmark = bookmarkByPlaylist[playlistID] else { return }
        bookmarkService.stopAccess(to: bookmark)
        folderURLByPlaylist[playlistID] = nil
        bookmarkByPlaylist[playlistID] = nil
    }

    /// Releases every open session.
    func releaseAll() {
        for bookmark in bookmarkByPlaylist.values { bookmarkService.stopAccess(to: bookmark) }
        folderURLByPlaylist.removeAll()
        bookmarkByPlaylist.removeAll()
    }

    // MARK: - One-shot editing access

    /// Runs `body` under a transient scoped session for `playlist`'s folder — its own
    /// `startAccess`/`stopAccess`, independent of any playback session on the same folder. A
    /// stale or denied bookmark triggers an interactive re-grant (`prompt`) and a bookmark
    /// refresh before one retry. Returns `nil` when access can't be obtained (the user cancels).
    func withAccess<T>(to playlist: Playlist, perform body: (URL) -> T) -> T? {
        guard let url = beginTransientAccess(to: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }
        return body(url)
    }

    /// The `async` form of `withAccess(to:perform:)`, for bodies that await disk I/O.
    func withAccess<T>(to playlist: Playlist, perform body: (URL) async -> T) async -> T? {
        guard let url = beginTransientAccess(to: playlist) else { return nil }
        defer { bookmarkService.stopAccess(to: playlist.folderBookmark) }
        return await body(url)
    }

    /// Opens a one-shot session for `playlist`'s folder, re-prompting and refreshing the bookmark
    /// when the saved one is stale or denied. Balanced by `bookmarkService.stopAccess`.
    private func beginTransientAccess(to playlist: Playlist) -> URL? {
        if let url = try? bookmarkService.startAccess(to: playlist.folderBookmark) { return url }
        guard let url = prompt.requestAccess(to: playlist),
              refreshBookmark(of: playlist, from: url) else { return nil }
        return try? bookmarkService.startAccess(to: playlist.folderBookmark)
    }

    /// Re-creates and persists `playlist`'s bookmark when macOS reports it stale (the folder moved
    /// or was renamed), so scoped access survives the next launch. Returns whether it refreshed;
    /// a no-op (and `false`) when the bookmark resolves cleanly or can't be re-created. No prompt —
    /// the proactive rescan path. The caller owns the save.
    @discardableResult
    func refreshStaleBookmark(for playlist: Playlist) -> Bool {
        guard let resolved = try? BookmarkService.resolve(playlist.folderBookmark), resolved.isStale,
              let refreshed = try? BookmarkService.makeBookmark(for: resolved.url) else { return false }
        playlist.folderBookmark = refreshed
        return true
    }

    /// Re-creates and persists `playlist`'s bookmark from a freshly granted URL, in memory.
    private func refreshBookmark(of playlist: Playlist, from url: URL) -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? BookmarkService.makeBookmark(for: url) else { return false }
        playlist.folderBookmark = bookmark
        playlist.folderPath = url.path(percentEncoded: false)
        return true
    }
}
