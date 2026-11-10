//
//  FileSystemService.swift
//  ShuTaPla
//
//  The serialization point for disk I/O. An `actor` so scans, renames, and trashing
//  never interleave on the same folder without explicit locking. A move runs off the
//  actor, on a Dispatch queue: it can take minutes, and `AppState` keeps it apart from its
//  playlist's re-scan.
//  Returns Sendable value types (`ScanResult`, `[ScannedFile]`, `FileBatchResult`)
//  that cross back to the main actor; it never touches SwiftData @Model objects.
//

import Foundation

// MARK: - Value types

/// One recognized media file found on disk — the naked listing, before any tag
/// derivation. `enumerateMedia(in:)` produces these; the higher-level scans derive
/// each file's tags from its name to produce a `ScannedFile`.
nonisolated struct MediaFile: Sendable, Equatable {
    let relativePath: String
    let fileName: String
    let mediaType: MediaType
    let cloudStatus: CloudStatus
    /// On-disk size and mtime, prefetched in the same enumerator pass — the staleness pair the
    /// reconcile compares against each surviving file's cached baseline. `nil` when unreadable.
    let fileSize: Int?
    let contentModified: Date?
}

/// A listed media file with its filename-derived tag fields — the unit the playlist layer
/// turns into (or reconciles against) a `PlaylistFile`. Derivation runs on the file-system
/// actor, off the main actor, so applying a scan never re-parses a filename on the main actor.
/// The main actor marks files whose `mediaType` differs from the playlist's as skipped.
nonisolated struct ScannedFile: Sendable, Equatable {
    let relativePath: String
    let fileName: String
    let mediaType: MediaType
    let cloudStatus: CloudStatus
    let fileSize: Int?
    let contentModified: Date?
    let tagNames: [String]
    let taggingStatus: TaggingStatus
}

/// The outcome of scanning a folder: every recognized media file, per-type
/// counts, and the dominant type (`nil` when no type reaches the threshold —
/// the folder is Mixed and the user is prompted to choose).
nonisolated struct ScanResult: Sendable, Equatable {
    let files: [ScannedFile]
    let counts: [MediaType: Int]
    let dominantType: MediaType?

    var isEmpty: Bool { files.isEmpty }
    var isMixed: Bool { files.isNotEmpty && dominantType == nil }
}

/// Result of a best-effort batch operation (trash, move). Files that failed are left
/// where they were and reported so the caller can surface a non-blocking notice and
/// leave their model entries untouched. A file that needs no work is in neither list.
nonisolated struct FileBatchResult: Sendable, Equatable {
    let succeeded: [URL]
    let failed: [URL]
    /// The cause of the first failure, for the notice.
    var firstError: String? = nil
}

nonisolated enum FileSystemError: Error, Equatable {
    case invalidName
    case nameCollision
    case fileNotFound
    case operationFailed(String)

    /// User-facing copy for the failure, surfaced by the file-edit flows.
    var userMessage: String {
        switch self {
        case .invalidName: return "That name isn't valid."
        case .nameCollision: return "A file with that name already exists."
        case .fileNotFound: return "The file no longer exists on disk."
        case .operationFailed(let detail): return "Rename failed: \(detail)"
        }
    }
}

// MARK: - Protocol

/// Injection seam for the file-system layer. Requirements are `async` so an
/// actor (production) and a plain struct/class (mocks) can both conform.
protocol FileSystemProviding: Sendable {
    func scanFolder(bookmark: Data) async throws -> ScanResult
    func rescan(bookmark: Data) async throws -> [ScannedFile]
    func renameFile(at url: URL, to newName: String) async throws -> URL
    func trashFiles(_ urls: [URL]) async -> FileBatchResult
    func moveFiles(_ urls: [URL], to folder: URL) async -> FileBatchResult
}

// MARK: - Service

actor FileSystemService {

    init() {}

    /// Resolves the bookmark, scans the folder under a transient scoped-access
    /// session, and classifies every recognized media file.
    func scanFolder(bookmark: Data) async throws -> ScanResult {
        try Self.scan(bookmark: bookmark)
    }

    /// Re-lists every file now on disk, each with its derived tags — the Update path's input.
    /// The reconcile diffs this against the playlist's current files in its own context, so no
    /// caller-supplied "known" set is needed (and none would be reliable across the background
    /// context anyway).
    func rescan(bookmark: Data) async throws -> [ScannedFile] {
        try Self.scan(bookmark: bookmark).files
    }

    /// Renames a file in place (same directory, new name component). Returns the
    /// new URL. A no-op rename returns the original URL; a name clash with a
    /// different file throws `.nameCollision`.
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        let fm = FileManager.default
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject empty, path-separated, and dot/hidden names (a leading dot covers
        // ".", "..", and extension-only names like ".mp4" that have no base).
        guard trimmed.isNotEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/") else {
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
    func trashFiles(_ urls: [URL]) async -> FileBatchResult {
        Self.eachBestEffort(urls) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    /// Moves files into `folder` under their own names, best-effort. `moveItem` never overwrites,
    /// so a name already taken in `folder` fails that file. A dataless iCloud file is downloaded
    /// by the move itself when it leaves iCloud Drive, and a move to another volume copies the
    /// bytes; a failed download or copy fails that file. That can take minutes, so the move runs
    /// off the actor, on a global Dispatch queue, which gives each batch its own thread: other
    /// disk work and other moves do not wait for it (a quick same-volume move never waits behind
    /// another batch's copy), and it blocks no cooperative-pool thread.
    /// `AppState.withDiskOpAccess` keeps a re-scan of the source playlist from overlapping it.
    /// A move to another volume writes the file under its final name while it copies, so a re-scan
    /// of a playlist that holds the destination can list the partial file. The next re-scan heals
    /// it: the copy ends with a new size and the source's mtime, which trips the staleness gate
    /// (`invalidateMetadataIfStale`). A copy by Finder into a playlist folder looks the same.
    ///
    /// A file already in `folder` is in neither list: `moveItem` into the file's own folder reports
    /// success and does nothing. The folders are compared by identity on disk, so another path to
    /// that folder (a symlink, the `/System/Volumes/Data` firmlink) matches too.
    nonisolated func moveFiles(_ urls: [URL], to folder: URL) async -> FileBatchResult {
        await DispatchQueue.global(qos: .utility).run {
            let destination = Self.identity(of: folder)
            let ownFolders = Set(urls.map { $0.deletingLastPathComponent() }).filter {
                destination != nil && Self.identity(of: $0)?.isEqual(destination) == true
            }
            return Self.eachBestEffort(urls.filter { !ownFolders.contains($0.deletingLastPathComponent()) }) {
                try FileManager.default.moveItem(at: $0, to: folder.appending(path: $0.lastPathComponent))
            }
        }
    }

    /// The file-system identity of the item at `url`, symlinks followed (`resourceValues` reads a
    /// link itself). `nil` when it can't be read.
    private nonisolated static func identity(of url: URL) -> (any NSObjectProtocol)? {
        try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

    /// Runs `operation` on each URL, collecting which succeeded and which threw.
    private nonisolated static func eachBestEffort(_ urls: [URL], _ operation: (URL) throws -> Void) -> FileBatchResult {
        var succeeded: [URL] = []
        var failed: [URL] = []
        var firstError: String?
        for url in urls {
            do {
                try operation(url)
                succeeded.append(url)
            } catch {
                failed.append(url)
                firstError = firstError ?? error.localizedDescription
            }
        }
        return FileBatchResult(succeeded: succeeded, failed: failed, firstError: firstError)
    }

    // MARK: - Scanning (stateless, off-actor)

    private nonisolated static func scan(bookmark: Data) throws -> ScanResult {
        try BookmarkService.withScopedAccess(to: bookmark) { try scan(directory: $0) }
    }

    /// Recursively enumerates `root`, keeping only recognized media files and recording each
    /// one's classification and initial cloud status — the naked listing, no tag derivation.
    /// Output is sorted by relative path for deterministic results. A cancelled task stops the
    /// listing with `CancellationError`: a file op cancels the playlist's re-scan and waits for it.
    nonisolated static func enumerateMedia(in root: URL) throws -> [MediaFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw FileSystemError.operationFailed("Could not enumerate \(root.path)")
        }

        var files: [MediaFile] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            // One fetch for every key the loop needs (regular-file test and cloud status),
            // reusing the values the enumerator prefetched rather than re-statting per use.
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            guard let type = AppConstants.mediaType(forExtension: fileURL.pathExtension) else { continue }

            files.append(MediaFile(
                relativePath: relativePath(of: fileURL, under: root),
                fileName: fileURL.lastPathComponent,
                mediaType: type,
                cloudStatus: CloudStatus.from(values),
                fileSize: values?.fileSize,
                contentModified: values?.contentModificationDate
            ))
        }

        files.sort { $0.relativePath < $1.relativePath }
        return files
    }

    /// A full folder scan: the naked listing with each file's tags derived from its name, plus
    /// the per-type counts and dominant type. Tag parsing (`TagParser.fields`) runs here, on the
    /// file-system actor's executor.
    nonisolated static func scan(directory root: URL) throws -> ScanResult {
        let media = try enumerateMedia(in: root)
        var counts: [MediaType: Int] = [:]
        for file in media { counts[file.mediaType, default: 0] += 1 }
        return ScanResult(
            files: media.map(deriveTags(of:)),
            counts: counts,
            dominantType: dominantType(counts: counts)
        )
    }

    /// Derives a listed file's tag fields from its name — the single tag-derivation site.
    private nonisolated static func deriveTags(of media: MediaFile) -> ScannedFile {
        let (tagNames, status) = TagParser.fields(for: media.fileName)
        return ScannedFile(
            relativePath: media.relativePath,
            fileName: media.fileName,
            mediaType: media.mediaType,
            cloudStatus: media.cloudStatus,
            fileSize: media.fileSize,
            contentModified: media.contentModified,
            tagNames: tagNames,
            taggingStatus: status
        )
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

    /// The path of `url` relative to `root`. Falls back to the last component when
    /// `url` isn't actually under `root`. Shared with the live cloud feed, which keys
    /// files by the same relative path the scan records. Compares path components, not a
    /// raw-string prefix, so a `/a/foo` root doesn't match `/a/foobar`, and trailing slashes and
    /// `.`/`..` don't matter. Two spellings of one folder (`/var` and `/private/var`, a symlinked
    /// root) match through symlink resolution, tried only when the plain comparison fails: it
    /// costs a few `lstat`s per URL, and the scan's enumerated URLs always share the root's spelling.
    nonisolated static func relativePath(of url: URL, under root: URL) -> String {
        func below(_ url: URL, _ root: URL) -> [String]? {
            let urlComponents = url.standardizedFileURL.pathComponents
            let rootComponents = root.standardizedFileURL.pathComponents
            guard urlComponents.starts(with: rootComponents) else { return nil }
            return Array(urlComponents.dropFirst(rootComponents.count))
        }
        guard let components = below(url, root)
                ?? below(url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath()),
              components.isNotEmpty else {
            return url.lastPathComponent
        }
        return components.joined(separator: "/")
    }

    /// A type is dominant when it makes up ≥ 80% of recognized media files.
    private nonisolated static func dominantType(counts: [MediaType: Int]) -> MediaType? {
        let total = counts.values.reduce(0, +)
        guard total > 0, let (type, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) / Double(total) >= AppConstants.dominanceThreshold else { return nil }
        return type
    }
}

extension FileSystemService: FileSystemProviding {}
