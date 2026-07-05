//
//  URLFingerprintTests.swift
//  ShuTaPlaTests
//
//  Content fingerprint: a cheap, content-derived identity stable across rename and
//  move, independent of the referencing folder, and distinct on any content or size
//  change. Backed by real temp files so the head/tail window reads run for real.
//

import Testing
import Foundation
@testable import ShuTaPla

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShuTaPlaFingerprintTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct URLFingerprintTests {

    /// Renaming a file changes its path but not its bytes, so the fingerprint is unchanged —
    /// which is what lets the cache survive a rename instead of orphaning the old thumbnail.
    @Test func fingerprintSurvivesRename() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appending(path: "clip.mp4")
        try Data("the same bytes".utf8).write(to: original)
        let before = original.contentFingerprint()

        let renamed = dir.appending(path: "renamed.mp4")
        try FileManager.default.moveItem(at: original, to: renamed)

        #expect(before != nil)
        #expect(before == renamed.contentFingerprint())
    }

    /// The same bytes copied to two different relative paths (root of one playlist, subfolder
    /// of another) fingerprint identically — the cross-folder sharing this whole feature targets.
    @Test func sameContentAtDifferentPathsMatches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let bytes = Data("shared clip content".utf8)
        let rooted = dir.appending(path: "clip.mp4")
        let nested = sub.appending(path: "clip.mp4")
        try bytes.write(to: rooted)
        try bytes.write(to: nested)

        #expect(rooted.contentFingerprint() == nested.contentFingerprint())
    }

    /// A byte-level content change yields a different fingerprint.
    @Test func contentChangeDiverges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "clip.mp4")

        try Data("original content".utf8).write(to: url)
        let before = url.contentFingerprint()
        try Data("altered content!".utf8).write(to: url)
        let after = url.contentFingerprint()

        #expect(before != nil)
        #expect(before != after)
    }

    /// Two files sharing head and tail windows but differing in total length diverge —
    /// the size-first hash update guards the shared-window case (padded / shared-header media).
    @Test func sizeDifferenceDivergesWithSharedWindows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let short = dir.appending(path: "short.bin")
        let long = dir.appending(path: "long.bin")

        // window = 4: head is the first 4 bytes, tail the last 4. Both files share both
        // windows ("HEAD"/"TAIL"); only the interior — never hashed — and the length differ.
        try Data("HEADTAIL".utf8).write(to: short)            // 8 bytes
        try Data("HEADxxxxTAIL".utf8).write(to: long)         // 12 bytes, same head/tail

        let a = short.contentFingerprint(windowBytes: 4)
        let b = long.contentFingerprint(windowBytes: 4)
        #expect(a != nil)
        #expect(a != b)
    }

    /// A file that can't be opened has no fingerprint — the produce path then yields no
    /// thumbnail and touches no cache entry.
    @Test func unreadableFileYieldsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appending(path: "does-not-exist.mp4")
        #expect(missing.contentFingerprint() == nil)
    }
}
