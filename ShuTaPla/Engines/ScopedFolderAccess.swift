//
//  ScopedFolderAccess.swift
//  ShuTaPla
//
//  The playback coordinator's per-playlist folder sessions. Each active playlist
//  holds one open security-scoped session to its folder, reference-counted through
//  `BookmarkService` so several playlists on one folder share a single grant. Keyed
//  by playlist id: the coordinator resolves file URLs against the open folder and
//  releases the session when the playlist stops.
//

import Foundation

@MainActor
final class ScopedFolderAccess {

    private let bookmarkService: BookmarkService

    /// Open folder URL per active playlist. The bookmark is kept alongside so the
    /// matching `stopAccess` can be issued on release.
    private var folderURLByPlaylist: [UUID: URL] = [:]
    private var bookmarkByPlaylist: [UUID: Data] = [:]

    init(bookmarkService: BookmarkService) {
        self.bookmarkService = bookmarkService
    }

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
}
