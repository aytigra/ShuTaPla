//
//  VideoDurationTests.swift
//  ShuTaPlaTests
//
//  Video length extraction over the real codec-labeled samples in
//  `test_media/videos`. A thumbnail render reports the running time its decode
//  determined — for the AVFoundation path (h264/h265/mpeg) and the libmpv fallback
//  (vp8/vp9 webm) alike — so the gallery's length badge rides back with the
//  thumbnail rather than reopening the file. Guards in particular that the libmpv
//  frame extraction reads `duration` while the file is loaded, not after it unloads.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct VideoDurationTests {

    /// `test_media/videos`, two levels up from this test file (the repo root).
    private static var videosDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "test_media/videos", directoryHint: .isDirectory)
    }

    /// The first sample whose filename starts with `prefix`, sidestepping the
    /// bracketed tag suffixes and `(N)` variants some names carry.
    private static func sample(prefix: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: videosDirectory, includingPropertiesForKeys: nil
        )
        return try #require(
            files.first { $0.lastPathComponent.hasPrefix(prefix) },
            "no sample with prefix \(prefix) in \(videosDirectory.path)"
        )
    }

    // h264/h265/mpeg take the AVFoundation path; vp8/vp9 fall back to libmpv.
    @Test(arguments: ["h264", "h265", "mpeg", "vp8", "vp9"])
    func renderReportsImageAndDuration(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)

        let rendered = await ThumbnailService.renderThumbnail(at: url, isVideo: true, maxPixelSize: 200)

        #expect(rendered.data != nil, "\(prefix): no thumbnail")
        let duration = try #require(rendered.duration, "\(prefix): no duration")
        #expect(duration.isFinite)
        #expect(duration > 0)
    }

    // The standalone probe (the list view's path) over a libmpv-only container.
    @Test(arguments: ["vp8", "vp9"])
    func mpvProbeReadsDuration(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)
        let duration = try #require(await MPVThumbnailer.duration(at: url))
        #expect(duration > 0)
    }
}
