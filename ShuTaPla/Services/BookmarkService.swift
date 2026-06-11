//
//  BookmarkService.swift
//  ShuTaPla
//
//  Security-scoped bookmark management. Creating and resolving a bookmark are
//  stateless (`nonisolated static`) so the file-system actor can use them off
//  the main actor. Long-lived access sessions are reference-counted on the main
//  actor so that several users of the same folder (e.g. an audio and a video
//  playlist on one directory) share a single scoped-access grant, released only
//  when the last one stops.
//

import Foundation

/// A bookmark resolved back to a URL, with the staleness flag the system reports.
nonisolated struct ResolvedBookmark: Sendable, Equatable {
    let url: URL
    /// True when macOS could resolve the bookmark but it should be recreated
    /// (the folder moved/renamed). The caller re-creates and re-persists it.
    let isStale: Bool
}

nonisolated enum BookmarkError: Error, Equatable {
    case creationFailed
    case resolutionFailed
    case stale
}

@MainActor
final class BookmarkService {

    /// One active scoped-access session per resolved folder URL. Keyed by URL
    /// (not the raw bookmark blob) so two playlists on the same folder — whose
    /// bookmark data may differ — share the same session.
    private var sessions: [URL: Session] = [:]

    private struct Session {
        var refCount: Int
        /// Whether `startAccessingSecurityScopedResource` actually granted scoped
        /// access (false for non-scoped bookmarks, e.g. in tests) so the matching
        /// `stop` is only issued when a `start` took effect.
        let didStartScopedAccess: Bool
    }

    init() {}

    // MARK: - Creation / resolution (stateless)

    /// Creates a persistent bookmark for a user-selected folder. Prefers a
    /// security-scoped bookmark; falls back to a plain one when scoped creation
    /// isn't available (outside the sandbox, as in tests).
    nonisolated static func makeBookmark(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        do {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw BookmarkError.creationFailed
        }
    }

    /// Resolves a bookmark to a URL. Tries a security-scoped resolution first,
    /// then a plain one, so it handles both scoped (production) and plain (test)
    /// bookmark data transparently.
    nonisolated static func resolve(_ bookmark: Data) throws -> ResolvedBookmark {
        func attempt(_ options: URL.BookmarkResolutionOptions) throws -> ResolvedBookmark {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return ResolvedBookmark(url: url, isStale: stale)
        }
        if let scoped = try? attempt([.withSecurityScope]) { return scoped }
        do {
            return try attempt([])
        } catch {
            throw BookmarkError.resolutionFailed
        }
    }

    // MARK: - Reference-counted access sessions

    /// Begins (or joins) a scoped-access session for the bookmark's folder.
    /// Throws `.stale` when the bookmark needs recreation so the caller can
    /// re-prompt for the folder.
    @discardableResult
    func startAccess(to bookmark: Data) throws -> URL {
        let resolved = try Self.resolve(bookmark)
        if resolved.isStale { throw BookmarkError.stale }
        let url = resolved.url

        if var session = sessions[url] {
            session.refCount += 1
            sessions[url] = session
            return url
        }
        let didStart = url.startAccessingSecurityScopedResource()
        sessions[url] = Session(refCount: 1, didStartScopedAccess: didStart)
        return url
    }

    /// Releases one reference. Scoped access is given up only when the last
    /// reference is dropped.
    func stopAccess(to bookmark: Data) {
        guard let resolved = try? Self.resolve(bookmark),
              var session = sessions[resolved.url] else { return }
        session.refCount -= 1
        if session.refCount <= 0 {
            if session.didStartScopedAccess {
                resolved.url.stopAccessingSecurityScopedResource()
            }
            sessions.removeValue(forKey: resolved.url)
        } else {
            sessions[resolved.url] = session
        }
    }

    /// Current reference count for the bookmark's folder (0 when not active).
    func referenceCount(for bookmark: Data) -> Int {
        guard let resolved = try? Self.resolve(bookmark) else { return 0 }
        return sessions[resolved.url]?.refCount ?? 0
    }
}
