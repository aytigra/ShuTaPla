//
//  URL+ScopedAccess.swift
//  ShuTaPla
//
//  Security-scoped access for a URL already resolved from a bookmark. The folder
//  case — resolve a bookmark, then access — lives on `BookmarkService`; this is the
//  leaf case where a worker is handed the file URL directly (the image engine
//  receives one from its `PlaybackSource`).
//

import Foundation

extension URL {

    /// Runs `body` while holding a security-scoped session for this URL, balancing
    /// the stop on exit (including when `body` throws). A no-op start for URLs that
    /// aren't security-scoped, so it's safe to wrap any file access.
    func withSecurityScopedAccess<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let didAccess = startAccessingSecurityScopedResource()
        defer { if didAccess { stopAccessingSecurityScopedResource() } }
        return try await body(self)
    }
}
