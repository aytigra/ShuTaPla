//
//  HDRProbeTests.swift
//  ShuTaPlaTests
//
//  The video HDR fact over the libmpv frame path (webm/mkv, which AVFoundation can't open). The
//  thumbnailer's `MPVThumbnailer.frame` decodes a representative frame and reads its `video-params`
//  colour tags as the HDR result the gallery routes to the sink: PQ/HLG is HDR, anything else a
//  determined SDR. The list-mode metadata extractor reads no HDR at all, so this is the surviving
//  producer boundary for the libmpv path.
//
//  Exercised over the committed `MediaFixture.hdr` — a 1.8 KB 10-bit VP9 tagged BT.2020 PQ — and
//  the SDR `.vp9`. A fixture small enough to commit publishes its colour tag together with the
//  decoded frame, so the tag is read reliably here.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct HDRProbeTests {

    // A BT.2020 PQ container through the libmpv frame path: the frame decode's colour tags come
    // back as an HDR gamma (PQ/HLG).
    @Test func frameReadsHDRForContainerTagged() async throws {
        let result = await MPVThumbnailer.frame(at: try MediaFixture.hdr.url, maxPixelSize: 64)
        guard case .video(let gamma, _) = result.hdr else {
            Issue.record("expected a video HDR result, got \(String(describing: result.hdr))")
            return
        }
        #expect(VideoColorTags.isHDR(gamma: gamma), "gamma \(String(describing: gamma))")
    }

    // An SDR libmpv-only container reads the other way — a non-PQ/HLG gamma is a determined SDR,
    // never a spurious `true`.
    @Test func frameReadsSDRForWebm() async throws {
        let result = await MPVThumbnailer.frame(at: try MediaFixture.vp9.url, maxPixelSize: 64)
        guard case .video(let gamma, _) = result.hdr else {
            Issue.record("expected a video HDR result, got \(String(describing: result.hdr))")
            return
        }
        #expect(!VideoColorTags.isHDR(gamma: gamma), "gamma \(String(describing: gamma))")
    }
}
