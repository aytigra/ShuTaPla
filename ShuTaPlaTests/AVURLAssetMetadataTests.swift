//
//  AVURLAssetMetadataTests.swift
//  ShuTaPlaTests
//
//  The AVFoundation moov-atom read (`AVURLAsset.videoMetadata`) that both the gallery
//  thumbnailer and the list-mode metadata service share: duration plus — for video — the
//  display size and mpv-style colour tags, all resolved from a single video-track load in one
//  concurrent pass. Exercised over the AV-decodable fixtures (h264/h265/mpeg); the webm/mkv
//  containers AVFoundation can't open are the libmpv fallback's job, covered elsewhere.
//

import Testing
import Foundation
import AVFoundation
@testable import ShuTaPla

@Suite struct AVURLAssetMetadataTests {

    // The video read reports a positive duration and display dimensions, and the colour tags it
    // resolves settle the SDR fixtures non-HDR (never a spurious `true`).
    @Test(arguments: [MediaFixture.h264, .h265, .mpeg])
    func videoMetadataReadsDurationSizeAndSDRTags(_ fixture: MediaFixture) async throws {
        let asset = AVURLAsset(url: try fixture.url)
        let (duration, size, gamma, _) = await asset.videoMetadata(wantsVideo: true)

        #expect(try #require(duration, "\(fixture): no duration") > 0)
        let dimensions = try #require(size, "\(fixture): no size")
        #expect(dimensions.width > 0)
        #expect(dimensions.height > 0)
        #expect(!VideoColorTags.isHDR(gamma: gamma), "\(fixture): SDR fixture read as HDR (\(String(describing: gamma)))")
    }

    // `wantsVideo == false` (the audio path) reads only the duration — no track load, so size and
    // colour tags come back `nil` even for a file that carries a video track.
    @Test func audioModeReadsDurationOnly() async throws {
        let asset = AVURLAsset(url: try MediaFixture.h264.url)
        let (duration, size, gamma, primaries) = await asset.videoMetadata(wantsVideo: false)

        #expect(try #require(duration) > 0)
        #expect(size == nil)
        #expect(gamma == nil)
        #expect(primaries == nil)
    }
}
