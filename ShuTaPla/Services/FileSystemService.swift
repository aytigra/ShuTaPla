//
//  FileSystemService.swift
//  ShuTaPla
//
//  The single serialization point for disk I/O. An `actor` so scans, renames,
//  and trashing never interleave on the same folder without explicit locking.
//  Returns Sendable value types (`ScanResult`, `UpdateDelta`, `TrashResult`)
//  that cross back to the main actor; it never touches SwiftData @Model objects.
//

import Foundation

// MARK: - Value types

/// One recognized media file found on disk. Classification and tag parsing are
/// done at scan time; the main actor turns these into `PlaylistFile` models,
/// marking files whose `mediaType` differs from the playlist's as skipped.
nonisolated struct ScannedFile: Sendable, Equatable {
    let relativePath: String
    let fileName: String
    let mediaType: MediaType
    let tags: [String]
    let taggingStatus: TaggingStatus
    let cloudStatus: CloudStatus
}

/// The outcome of scanning a folder: every recognized media file, per-type
/// counts, and the dominant type (`nil` when no type reaches the threshold —
/// the folder is Mixed and the user is prompted to choose).
nonisolated struct ScanResult: Sendable, Equatable {
    let files: [ScannedFile]
    let counts: [MediaType: Int]
    let dominantType: MediaType?

    var isEmpty: Bool { files.isEmpty }
    var isMixed: Bool { !files.isEmpty && dominantType == nil }
}

/// Difference between a playlist's known files and what's now on disk.
nonisolated struct UpdateDelta: Sendable, Equatable {
    let added: [ScannedFile]
    let removedRelativePaths: [String]

    var isEmpty: Bool { added.isEmpty && removedRelativePaths.isEmpty }
}

/// Result of a (best-effort) trash operation. Files that failed are left on
/// disk and reported so the caller can surface a non-blocking notice and leave
/// their model entries untouched.
nonisolated struct TrashResult: Sendable, Equatable {
    let trashed: [URL]
    let failed: [URL]
}

nonisolated enum FileSystemError: Error, Equatable {
    case invalidName
    case nameCollision
    case fileNotFound
    case operationFailed(String)
}

// MARK: - Protocol

/// Injection seam for the file-system layer. Requirements are `async` so an
/// actor (production) and a plain struct/class (mocks) can both conform.
protocol FileSystemProviding: Sendable {
    func scanFolder(bookmark: Data) async throws -> ScanResult
    func updatePlaylist(bookmark: Data, knownRelativePaths: Set<String>) async throws -> UpdateDelta
    func renameFile(at url: URL, to newName: String) async throws -> URL
    func trashFiles(_ urls: [URL]) async throws -> TrashResult
}

// MARK: - Service

actor FileSystemService {

    init() {}

    /// Resolves the bookmark, scans the folder under a transient scoped-access
    /// session, and classifies every recognized media file.
    func scanFolder(bookmark: Data) async throws -> ScanResult {
        try Self.scan(bookmark: bookmark)
    }

    /// Re-scans and reports new files (on disk, not yet known) and removed files
    /// (known, no longer on disk). `knownRelativePaths` should include skipped
    /// entries so they aren't re-reported as added.
    func updatePlaylist(bookmark: Data, knownRelativePaths: Set<String>) async throws -> UpdateDelta {
        let result = try Self.scan(bookmark: bookmark)
        let currentPaths = Set(result.files.map(\.relativePath))
        let added = result.files.filter { !knownRelativePaths.contains($0.relativePath) }
        let removed = knownRelativePaths.subtracting(currentPaths)
        return UpdateDelta(added: added, removedRelativePaths: removed.sorted())
    }

    /// Renames a file in place (same directory, new name component). Returns the
    /// new URL. A no-op rename returns the original URL; a name clash with a
    /// different file throws `.nameCollision`.
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        let fm = FileManager.default
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject empty, path-separated, and dot/hidden names (a leading dot covers
        // ".", "..", and extension-only names like ".mp4" that have no base).
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/") else {
            throw FileSystemError.invalidName
        }
        guard fm.fileExists(atPath: url.path) else { throw FileSystemError.fileNotFound }

        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if destination.standardizedFileURL == url.standardizedFileURL { return url }

        // A case-only rename on a case-insensitive volume points at the same
        // file, so it isn't a collision — let the move perform the case change.
        let caseOnlyChange = url.path.compare(destination.path, options: .caseInsensitive) == .orderedSame
        if !caseOnlyChange, fm.fileExists(atPath: destination.path) {
            throw FileSystemError.nameCollision
        }
        do {
            try fm.moveItem(at: url, to: destination)
        } catch {
            throw FileSystemError.operationFailed(error.localizedDescription)
        }
        return destination
    }

    /// Moves files to the Trash, best-effort. Files that fail are reported, not
    /// thrown — the caller keeps their model entries and notifies the user.
    func trashFiles(_ urls: [URL]) async throws -> TrashResult {
        let fm = FileManager.default
        var trashed: [URL] = []
        var failed: [URL] = []
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
            } catch {
                failed.append(url)
            }
        }
        return TrashResult(trashed: trashed, failed: failed)
    }

    // MARK: - Scanning (stateless, off-actor)

    private nonisolated static func scan(bookmark: Data) throws -> ScanResult {
        try BookmarkService.withScopedAccess(to: bookmark) { try scan(directory: $0) }
    }

    /// Recursively enumerates `root`, keeping only recognized media files and
    /// recording each one's classification, parsed tags, and initial cloud
    /// status. Output is sorted by relative path for deterministic results.
    nonisolated static func scan(directory root: URL) throws -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw FileSystemError.operationFailed("Could not enumerate \(root.path)")
        }

        let rootPath = root.standardizedFileURL.path
        var files: [ScannedFile] = []
        var counts: [MediaType: Int] = [:]

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            guard let type = AppConstants.mediaType(forExtension: fileURL.pathExtension) else { continue }

            let fileName = fileURL.lastPathComponent
            let (tags, status) = TagParser.fields(for: fileName)
            files.append(ScannedFile(
                relativePath: relativePath(of: fileURL, under: rootPath),
                fileName: fileName,
                mediaType: type,
                tags: tags,
                taggingStatus: status,
                cloudStatus: cloudStatus(for: fileURL)
            ))
            counts[type, default: 0] += 1
        }

        files.sort { $0.relativePath < $1.relativePath }
        return ScanResult(files: files, counts: counts, dominantType: dominantType(counts: counts))
    }

    // MARK: - Shuffle

    /// Fisher-Yates shuffle. Takes a generator so callers can seed it for
    /// deterministic ordering in tests.
    nonisolated static func fisherYatesShuffle<Element>(
        _ elements: [Element],
        using generator: inout some RandomNumberGenerator
    ) -> [Element] {
        var result = elements
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            let j = Int.random(in: 0...i, using: &generator)
            result.swapAt(i, j)
        }
        return result
    }

    nonisolated static func fisherYatesShuffle<Element>(_ elements: [Element]) -> [Element] {
        var rng = SystemRandomNumberGenerator()
        return fisherYatesShuffle(elements, using: &rng)
    }

    // MARK: - Helpers

    private nonisolated static func relativePath(of url: URL, under rootPath: String) -> String {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return url.lastPathComponent }
        var rel = String(full.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    private nonisolated static func cloudStatus(for url: URL) -> CloudStatus {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]), values.isUbiquitousItem == true else {
            return .local
        }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        switch values.ubiquitousItemDownloadingStatus {
        case .some(.notDownloaded): return .inCloud
        default:                    return .local
        }
    }

    /// A type is dominant when it makes up ≥ 80% of recognized media files.
    private nonisolated static func dominantType(counts: [MediaType: Int]) -> MediaType? {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }
        return counts.first { Double($0.value) / Double(total) >= AppConstants.dominanceThreshold }?.key
    }
}

extension FileSystemService: FileSystemProviding {}
