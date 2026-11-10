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
    /// (the folder moved/renamed). `startAccess` re-creates it.
    let isStale: Bool
}

nonisolated enum BookmarkError: Error, Equatable {
    case creationFailed
    case resolutionFailed
    case fileNotFound
}

@MainActor
final class BookmarkService {

    /// One active scoped-access session per resolved folder URL. Keyed by URL
    /// (not the raw bookmark blob) so two playlists on the same folder — whose
    /// bookmark data may differ — share the same session.
    private var sessions: [URL: Session] = [:]

    private struct Session {
        var refCount: Int
        /// Whether `startAccessingSecurityScopedResource` took effect, so the matching
        /// `stop` is issued only then.
        let didStartScopedAccess: Bool
    }

    init() {}

    // MARK: - Creation / resolution (stateless)

    /// Creates a persistent security-scoped bookmark for a folder the process can access: one the
    /// user just picked, or one under an open scoped session.
    nonisolated static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw BookmarkError.creationFailed
        }
    }

    /// Resolves a security-scoped bookmark to a URL. A bookmark follows its folder into the Trash, so
    /// a folder in the Trash counts as unresolvable: callers then treat it as deleted, and the
    /// stored bookmark still resolves to the folder's place after Put Back.
    nonisolated static func resolve(_ bookmark: Data) throws -> ResolvedBookmark {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw BookmarkError.resolutionFailed
        }
        if isInTrash(url) { throw BookmarkError.resolutionFailed }
        return ResolvedBookmark(url: url, isStale: stale)
    }

    /// The empty domain mask checks the Trash of the item's own location (`.Trashes/<uid>`
    /// on another volume, the iCloud Drive Trash); `.userDomainMask` checks only `~/.Trash`.
    private nonisolated static func isInTrash(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: [], toItemAt: url)
        return relationship == .contains
    }

    // MARK: - Scoped access (stateless)

    /// Resolves `bookmark` to its folder, opens a transient security-scoped session,
    /// runs `body` with the folder URL, and balances the matching stop on exit —
    /// including when `body` throws. Throws `BookmarkError.resolutionFailed` when the
    /// bookmark can't be resolved; best-effort callers wrap the call in `try?`.
    /// Staleness is ignored: these are one-shot reads, not the long-lived sessions
    /// `startAccess(to:)` reference-counts.
    nonisolated static func withScopedAccess<T>(
        to bookmark: Data,
        _ body: (URL) throws -> T
    ) throws -> T {
        let resolved = try resolve(bookmark)
        let didAccess = resolved.url.startAccessingSecurityScopedResource()
        defer { if didAccess { resolved.url.stopAccessingSecurityScopedResource() } }
        return try body(resolved.url)
    }

    /// The `async` form of `withScopedAccess(to:_:)`, for workers that await inside
    /// the scoped session (decode/probe).
    nonisolated static func withScopedAccess<T>(
        to bookmark: Data,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let resolved = try resolve(bookmark)
        let didAccess = resolved.url.startAccessingSecurityScopedResource()
        defer { if didAccess { resolved.url.stopAccessingSecurityScopedResource() } }
        return try await body(resolved.url)
    }

    /// Appends `relativePath` to the file's folder and runs `body` with that file URL
    /// under scoped access. When `folder` is supplied — a directory a surface already
    /// resolved once and holds open via a reference-counted `startAccess` session — the
    /// per-file read appends the path directly, skipping the `resolve` + start/stop that
    /// the bookmark path pays on every call (the session's grant already covers it). When
    /// `folder` is `nil` (tests, non-surface callers) it resolves `bookmark` per file as
    /// before. Throws `.resolutionFailed` when the folder can't be resolved and
    /// `.fileNotFound` when the file is gone; best-effort callers fold both into a nil
    /// result with `try?`.
    nonisolated static func withResolvedFile<T>(
        folder: URL? = nil,
        bookmark: Data,
        relativePath: String,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        func run(in directory: URL) async throws -> T {
            let fileURL = directory.appending(path: relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw BookmarkError.fileNotFound
            }
            return try await body(fileURL)
        }
        if let folder { return try await run(in: folder) }
        return try await withScopedAccess(to: bookmark) { try await run(in: $0) }
    }

    // MARK: - Reference-counted access sessions

    /// Begins (or joins) a scoped-access session for the bookmark's folder. A stale bookmark (the
    /// folder moved or was renamed) still opens the folder; `refreshed` is its re-created bookmark,
    /// or `nil` when the bookmark is current or can't be re-created. The sandbox creates a scoped
    /// bookmark only for a folder the process is accessing, so the re-creation runs in the session.
    func startAccess(to bookmark: Data) throws -> (url: URL, refreshed: Data?) {
        let resolved = try Self.resolve(bookmark)
        let url = resolved.url

        if var session = sessions[url] {
            session.refCount += 1
            sessions[url] = session
        } else {
            let didStart = url.startAccessingSecurityScopedResource()
            sessions[url] = Session(refCount: 1, didStartScopedAccess: didStart)
        }
        return (url, resolved.isStale ? try? Self.makeBookmark(for: url) : nil)
    }

    /// Releases one reference to the session `startAccess` returned `url` for. Scoped access is given
    /// up only when the last reference is dropped. The release takes the URL, the key the session is
    /// stored under: the bookmark can resolve elsewhere by then (the folder was renamed, or the
    /// bookmark refreshed).
    func stopAccess(to url: URL) {
        guard var session = sessions[url] else { return }
        session.refCount -= 1
        if session.refCount <= 0 {
            if session.didStartScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
            sessions.removeValue(forKey: url)
        } else {
            sessions[url] = session
        }
    }

    /// Current reference count for the bookmark's folder (0 when not active).
    func referenceCount(for bookmark: Data) -> Int {
        guard let resolved = try? Self.resolve(bookmark) else { return 0 }
        return sessions[resolved.url]?.refCount ?? 0
    }
}
