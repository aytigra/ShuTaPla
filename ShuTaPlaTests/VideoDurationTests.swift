//
//  VideoDurationTests.swift
//  ShuTaPlaTests
//
//  Video metadata extraction over the committed per-codec fixtures (`MediaFixture`).
//  A thumbnail render reports the running time and pixel dimensions its decode
//  determined — for the AVFoundation path (h264/h265/mpeg) and the libmpv fallback
//  (vp8/vp9 webm) alike — so the gallery's badge and the preview's cached shape ride
//  back with the thumbnail rather than reopening the file. Guards in particular that
//  the libmpv frame extraction reads its metadata while the file is loaded, not after
//  it unloads.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct VideoDurationTests {

    // h264/h265/mpeg take the AVFoundation path; vp8/vp9 fall back to libmpv. Either way
    // the render reports a thumbnail plus the media's duration and pixel dimensions — the
    // gallery byproduct the sink folds onto the model. (File size is the caller's `stat`,
    // not the render's, so it stays `nil` here.)
    @Test(arguments: MediaFixture.allCases)
    func renderReportsImageAndMetadata(_ fixture: MediaFixture) async throws {
        let url = try fixture.url

        let rendered = await ThumbnailService.renderThumbnail(at: url, isVideo: true, maxPixelSize: 200)

        #expect(rendered.data != nil, "\(fixture): no thumbnail")
        #expect(try #require(rendered.metadata.duration, "\(fixture): no duration") > 0)
        #expect(try #require(rendered.metadata.width, "\(fixture): no width") > 0)
        #expect(try #require(rendered.metadata.height, "\(fixture): no height") > 0)
    }

    // The libmpv frame path directly, over a container AVFoundation can't open: the single
    // decode yields both the frame and the metadata (duration + demuxer dimensions), read at
    // `FILE_LOADED` while the file is loaded.
    @Test(arguments: [MediaFixture.vp8, .vp9])
    func frameReportsImageAndMetadata(_ fixture: MediaFixture) async throws {
        let url = try fixture.url
        let frame = await MPVThumbnailer.frame(at: url, maxPixelSize: 200)
        #expect(frame.image != nil, "\(fixture): no frame")
        #expect(try #require(frame.metadata.duration) > 0)
        #expect(try #require(frame.metadata.width) > 0)
        #expect(try #require(frame.metadata.height) > 0)
    }

    // The standalone probe (the list view's fallback path) over a libmpv-only container:
    // duration and display dimensions both read at `FILE_LOADED` under `vo=null`.
    @Test(arguments: [MediaFixture.vp8, .vp9])
    func mpvProbeReadsMetadata(_ fixture: MediaFixture) async throws {
        let url = try fixture.url
        let metadata = await MPVThumbnailer.metadata(at: url)
        #expect(try #require(metadata.duration) > 0)
        #expect(try #require(metadata.width) > 0)
        #expect(try #require(metadata.height) > 0)
    }

    // Both extraction paths race mpv's own startup and property updates: an initial idle
    // event can precede the load, and `duration` can lag `FILE_LOADED` by an instant.
    // A single call passes most of the time, so only repetition exposes a bail that
    // returns empty or duration-less metadata for a perfectly healthy file.
    @Test func repeatedExtractionsAlwaysReportMetadata() async throws {
        let url = try MediaFixture.vp8.url
        for attempt in 1...12 {
            let metadata = await MPVThumbnailer.metadata(at: url)
            #expect(metadata.duration != nil, "probe attempt \(attempt): no duration")
            #expect(metadata.width != nil, "probe attempt \(attempt): no width")

            let frame = await MPVThumbnailer.frame(at: url, maxPixelSize: 200)
            #expect(frame.metadata.duration != nil, "frame attempt \(attempt): no duration")
            #expect(frame.metadata.width != nil, "frame attempt \(attempt): no width")
        }
    }
}
