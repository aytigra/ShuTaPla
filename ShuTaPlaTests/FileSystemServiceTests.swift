//
//  FileSystemServiceTests.swift
//  ShuTaPlaTests
//
//  Task 3 — integration tests over temp directories for scanning, update
//  detection, rename, trash, dominance, shuffle, and bookmark round-trip /
//  reference counting. Plus mock-conformance to FileSystemProviding.
//

import Testing
import Foundation
@testable import ShuTaPla

// MARK: - Temp directory helpers

private enum TempFS {
    static func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuTaPlaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deterministic generator (SplitMix64) for reproducible shuffle tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - FileSystemService

struct FileSystemServiceTests {

    private func bookmark(for dir: URL) throws -> Data {
        try BookmarkService.makeBookmark(for: dir)
    }

    @Test func scanClassifiesAndCounts() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        try TempFS.write("clip.mp4", in: dir)
        try TempFS.write("movie.webm", in: dir)
        try TempFS.write("photo.jpg", in: dir)
        try TempFS.write("song.mp3", in: dir)
        try TempFS.write("notes.txt", in: dir)            // unrecognized → ignored

        let result = try await FileSystemService().scanFolder(bookmark: bookmark(for: dir))

        #expect(result.files.count == 4)
        #expect(result.counts[.video] == 2)
        #expect(result.counts[.image] == 1)
        #expect(result.counts[.audio] == 1)
        #expect(result.files.allSatisfy { !$0.relativePath.isEmpty })
        #expect(result.files.allSatisfy { $0.cloudStatus == .local })
    }

    @Test func scanParsesTags() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        try TempFS.write("sunset [beach sunny].mp4", in: dir)
        try TempFS.write("plain.mp4", in: dir)
        try TempFS.write("broken [a].mp4", in: dir)        // token too short → invalid

        let result = try await FileSystemService().scanFolder(bookmark: bookmark(for: dir))
        let byName = Dictionary(uniqueKeysWithValues: result.files.map { ($0.fileName, $0) })

        #expect(byName["sunset [beach sunny].mp4"]?.taggingStatus == .valid)
        #expect(byName["sunset [beach sunny].mp4"]?.tags == ["beach", "sunny"])
        #expect(byName["plain.mp4"]?.taggingStatus == .untagged)
        #expect(byName["broken [a].mp4"]?.taggingStatus == .invalid)
    }

    @Test func scanRecursesSubdirectories() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        try TempFS.write("top.mp4", in: dir)
        try TempFS.write("nested/inner.mp4", in: dir)

        let result = try await FileSystemService().scanFolder(bookmark: bookmark(for: dir))
        let paths = Set(result.files.map(\.relativePath))

        #expect(result.files.count == 2)
        #expect(paths.contains("top.mp4"))
        #expect(paths.contains("nested/inner.mp4"))
    }

    @Test func dominanceAutoSelectsAtThreshold() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        for i in 0..<8 { try TempFS.write("v\(i).mp4", in: dir) }
        for i in 0..<2 { try TempFS.write("i\(i).jpg", in: dir) }   // 80% video

        let result = try await FileSystemService().scanFolder(bookmark: bookmark(for: dir))
        #expect(result.dominantType == .video)
        #expect(result.isMixed == false)
    }

    @Test func dominanceBelowThresholdIsMixed() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        for i in 0..<7 { try TempFS.write("v\(i).mp4", in: dir) }
        for i in 0..<3 { try TempFS.write("i\(i).jpg", in: dir) }   // 70% video

        let result = try await FileSystemService().scanFolder(bookmark: bookmark(for: dir))
        #expect(result.dominantType == nil)
        #expect(result.isMixed == true)
    }

    @Test func emptyFolderHasNoDominanceAndIsNotMixed() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        try TempFS.write("readme.txt", in: dir)            // no recognized media

        let result = try await FileSystemService().scanFolder(bookmark: bookmark(for: dir))
        #expect(result.isEmpty)
        #expect(result.dominantType == nil)
        #expect(result.isMixed == false)
    }

    @Test func updateDetectsAddedAndRemoved() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        try TempFS.write("a.mp4", in: dir)
        try TempFS.write("b.mp4", in: dir)

        let service = FileSystemService()
        let known: Set<String> = ["a.mp4", "b.mp4"]

        // Add one, remove one.
        try TempFS.write("c.mp4", in: dir)
        TempFS.remove(dir.appendingPathComponent("b.mp4"))

        let delta = try await service.updatePlaylist(bookmark: bookmark(for: dir), knownRelativePaths: known)
        #expect(delta.added.map(\.relativePath) == ["c.mp4"])
        #expect(delta.removedRelativePaths == ["b.mp4"])
    }

    @Test func renameMovesFileOnDisk() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let original = try TempFS.write("sunset.jpg", in: dir)

        let newURL = try await FileSystemService().renameFile(at: original, to: "sunset [beach].jpg")

        #expect(newURL.lastPathComponent == "sunset [beach].jpg")
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func renameRejectsCollision() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let a = try TempFS.write("a.mp4", in: dir)
        try TempFS.write("b.mp4", in: dir)

        await #expect(throws: FileSystemError.nameCollision) {
            try await FileSystemService().renameFile(at: a, to: "b.mp4")
        }
    }

    @Test func renameRejectsInvalidName() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let a = try TempFS.write("a.mp4", in: dir)
        let service = FileSystemService()

        await #expect(throws: FileSystemError.invalidName) {
            try await service.renameFile(at: a, to: "  ")
        }
        await #expect(throws: FileSystemError.invalidName) {
            try await service.renameFile(at: a, to: "sub/b.mp4")
        }
    }

    @Test func trashMovesFilesToTrash() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let a = try TempFS.write("a.mp4", in: dir)
        let b = try TempFS.write("b.mp4", in: dir)

        let result = try await FileSystemService().trashFiles([a, b])

        #expect(result.failed.isEmpty)
        #expect(Set(result.trashed) == Set([a, b]))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func fisherYatesIsDeterministicAndAPermutation() {
        let input = Array(0..<50)

        var g1 = SeededGenerator(seed: 42)
        var g2 = SeededGenerator(seed: 42)
        let s1 = FileSystemService.fisherYatesShuffle(input, using: &g1)
        let s2 = FileSystemService.fisherYatesShuffle(input, using: &g2)

        #expect(s1 == s2)                 // deterministic for a given seed
        #expect(s1.sorted() == input)     // same multiset → valid permutation
        #expect(s1 != input)              // 50 elements: shuffle changes order
    }
}

// MARK: - BookmarkService

@MainActor
struct BookmarkServiceTests {

    @Test func roundTripResolvesToSameFolder() throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }

        let data = try BookmarkService.makeBookmark(for: dir)
        let resolved = try BookmarkService.resolve(data)

        #expect(resolved.url.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
    }

    @Test func referenceCountingSharesOneSession() throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let data = try BookmarkService.makeBookmark(for: dir)
        let service = BookmarkService()

        #expect(service.referenceCount(for: data) == 0)
        try service.startAccess(to: data)
        try service.startAccess(to: data)
        #expect(service.referenceCount(for: data) == 2)

        service.stopAccess(to: data)
        #expect(service.referenceCount(for: data) == 1)
        service.stopAccess(to: data)
        #expect(service.referenceCount(for: data) == 0)
    }

    // MARK: - Scoped-access helpers

    @Test func withScopedAccessRunsBodyWithResolvedFolder() throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let data = try BookmarkService.makeBookmark(for: dir)

        let path = try BookmarkService.withScopedAccess(to: data) { $0.path }
        #expect(URL(filePath: path).resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
    }

    @Test func withScopedAccessThrowsWhenBookmarkUnresolvable() {
        #expect(throws: BookmarkError.self) {
            try BookmarkService.withScopedAccess(to: Data([0x00])) { _ in 0 }
        }
    }

    @Test func withResolvedFileGivesFileURLForExistingFile() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        _ = try TempFS.write("clip [a].mp4", in: dir)
        let data = try BookmarkService.makeBookmark(for: dir)

        let name = try await BookmarkService.withResolvedFile(
            bookmark: data, relativePath: "clip [a].mp4"
        ) { $0.lastPathComponent }
        #expect(name == "clip [a].mp4")
    }

    @Test func withResolvedFileThrowsFileNotFoundForMissingFile() async throws {
        let dir = try TempFS.makeDir()
        defer { TempFS.remove(dir) }
        let data = try BookmarkService.makeBookmark(for: dir)

        await #expect(throws: BookmarkError.fileNotFound) {
            try await BookmarkService.withResolvedFile(bookmark: data, relativePath: "missing.mp4") { _ in () }
        }
    }
}

// MARK: - Mock conformance

private struct MockFileSystem: FileSystemProviding {
    var scanResult: ScanResult

    func scanFolder(bookmark: Data) async throws -> ScanResult { scanResult }
    func updatePlaylist(bookmark: Data, knownRelativePaths: Set<String>) async throws -> UpdateDelta {
        UpdateDelta(added: [], removedRelativePaths: [])
    }
    func renameFile(at url: URL, to newName: String) async throws -> URL {
        url.deletingLastPathComponent().appendingPathComponent(newName)
    }
    func trashFiles(_ urls: [URL]) async throws -> TrashResult {
        TrashResult(trashed: urls, failed: [])
    }
}

struct FileSystemProvidingMockTests {

    @Test func mockConformsAndInjects() async throws {
        let sample = ScanResult(
            files: [ScannedFile(
                relativePath: "a.mp4", fileName: "a.mp4", mediaType: .video,
                tags: [], taggingStatus: .untagged, cloudStatus: .local
            )],
            counts: [.video: 1],
            dominantType: .video
        )
        let provider: FileSystemProviding = MockFileSystem(scanResult: sample)

        let result = try await provider.scanFolder(bookmark: Data())
        #expect(result.files.count == 1)
        #expect(result.dominantType == .video)

        let renamed = try await provider.renameFile(at: URL(filePath: "/tmp/a.mp4"), to: "b.mp4")
        #expect(renamed.lastPathComponent == "b.mp4")
    }
}
