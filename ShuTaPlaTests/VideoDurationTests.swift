//
//  VideoDurationTests.swift
//  ShuTaPlaTests
//
//  Video metadata extraction over the real codec-labeled samples in
//  `test_media/videos`. A thumbnail render reports the running time and pixel
//  dimensions its decode determined — for the AVFoundation path (h264/h265/mpeg) and
//  the libmpv fallback (vp8/vp9 webm) alike — so the gallery's badge and the preview's
//  cached shape ride back with the thumbnail rather than reopening the file. Guards in
//  particular that the libmpv frame extraction reads its metadata while the file is
//  loaded, not after it unloads.
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

    // h264/h265/mpeg take the AVFoundation path; vp8/vp9 fall back to libmpv. Either way
    // the render reports a thumbnail plus the media's duration and pixel dimensions — the
    // gallery byproduct the sink folds onto the model. (File size is the caller's `stat`,
    // not the render's, so it stays `nil` here.)
    @Test(arguments: ["h264", "h265", "mpeg", "vp8", "vp9"])
    func renderReportsImageAndMetadata(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)

        let rendered = await ThumbnailService.renderThumbnail(at: url, isVideo: true, maxPixelSize: 200)

        #expect(rendered.data != nil, "\(prefix): no thumbnail")
        #expect(try #require(rendered.metadata.duration, "\(prefix): no duration") > 0)
        #expect(try #require(rendered.metadata.width, "\(prefix): no width") > 0)
        #expect(try #require(rendered.metadata.height, "\(prefix): no height") > 0)
    }

    // The libmpv frame path directly, over a container AVFoundation can't open: the single
    // decode yields both the frame and the metadata (duration + demuxer dimensions), read at
    // `FILE_LOADED` while the file is loaded.
    @Test(arguments: ["vp8", "vp9"])
    func frameReportsImageAndMetadata(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)
        let frame = await MPVThumbnailer.frame(at: url, maxPixelSize: 200)
        #expect(frame.image != nil, "\(prefix): no frame")
        #expect(try #require(frame.metadata.duration) > 0)
        #expect(try #require(frame.metadata.width) > 0)
        #expect(try #require(frame.metadata.height) > 0)
    }

    // The standalone probe (the list view's fallback path) over a libmpv-only container:
    // duration and display dimensions both read at `FILE_LOADED` under `vo=null`.
    @Test(arguments: ["vp8", "vp9"])
    func mpvProbeReadsMetadata(_ prefix: String) async throws {
        let url = try Self.sample(prefix: prefix)
        let metadata = await MPVThumbnailer.metadata(at: url)
        #expect(try #require(metadata.duration) > 0)
        #expect(try #require(metadata.width) > 0)
        #expect(try #require(metadata.height) > 0)
    }
}
