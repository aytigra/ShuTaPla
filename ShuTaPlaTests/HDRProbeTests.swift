//
//  HDRProbeTests.swift
//  ShuTaPlaTests
//
//  The video HDR badge over the libmpv fallback path (webm/mkv, which AVFoundation can't
//  open). `MediaMetadataService.extract` settles `isHDR` from the colour transfer the probe
//  reads off `video-params/gamma`: PQ/HLG is HDR, anything else is a determined `false`.
//
//  Exercised over the committed `MediaFixture.hdr` — a 1.8 KB 10-bit VP9 tagged BT.2020 PQ —
//  and the SDR `.vp9`. These guard the end state of the pipeline: a PQ container settles the
//  badge on, an SDR one settles it off. They do not reproduce the timing race the probe's
//  gamma-wait exists for: that only surfaces on heavy Dolby-Vision samples whose colour tag
//  lags the demuxer duration by several event-loop turns; a fixture small enough to commit
//  publishes gamma together with the duration, so it settles correctly with or without the
//  wait.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct HDRProbeTests {

    // A BT.2020 PQ container through the libmpv fallback: the whole extract chain reports an
    // HDR gamma (PQ/HLG) and settles `isHDR == true`.
    @Test func extractSettlesHDRForContainerTagged() async throws {
        let url = try MediaFixture.hdr.url
        let bookmark = try BookmarkService.makeBookmark(for: url.deletingLastPathComponent())

        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: url.lastPathComponent, mediaType: .video, isSkipped: false
        )

        #expect(VideoColorTags.isHDR(gamma: metadata.hdrGamma), "gamma \(String(describing: metadata.hdrGamma))")
        #expect(metadata.isHDR == true)
    }

    // The raw probe boundary directly over the sample: `metadata(at:)` reads the colour tag,
    // so `hdrGamma` comes back as the file's PQ transfer rather than `nil`.
    @Test func probeReadsHDRGamma() async throws {
        let url = try MediaFixture.hdr.url
        let metadata = await MPVThumbnailer.metadata(at: url)
        #expect(VideoColorTags.isHDR(gamma: metadata.hdrGamma), "gamma \(String(describing: metadata.hdrGamma))")
    }

    // An SDR libmpv-only container settles the flag the other way — a non-PQ/HLG gamma is a
    // determined `false`, never a spurious `true`. Guards the wait-for-gamma change against
    // over-tagging SDR content.
    @Test func extractSettlesSDRFalseForWebm() async throws {
        let url = try MediaFixture.vp9.url
        let bookmark = try BookmarkService.makeBookmark(for: url.deletingLastPathComponent())

        let metadata = await MediaMetadataService.extract(
            bookmark: bookmark, relativePath: url.lastPathComponent, mediaType: .video, isSkipped: false
        )

        #expect(metadata.isHDR == false)
    }
}
