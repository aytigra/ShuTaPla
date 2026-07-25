//
//  AVURLAssetMetadataTests.swift
//  ShuTaPlaTests
//
//  The AVFoundation moov-atom reads on `AVURLAsset`: `videoMetadata` (duration plus — for video —
//  the display size, the list-mode service's and thumbnailer's shared reader) and `videoColorTags`
//  (the mpv-style colour tags the thumbnailer alone reads as its decode-time HDR fact). No frame is
//  decoded. Exercised over the AV-decodable fixtures (h264/h265/mpeg); the webm/mkv containers
//  AVFoundation can't open are the libmpv fallback's job, covered elsewhere.
//

import Testing
import Foundation
import AVFoundation
@testable import ShuTaPla

@Suite struct AVURLAssetMetadataTests {

    // The video read reports a positive duration and display dimensions.
    @Test(arguments: [MediaFixture.h264, .h265, .mpeg])
    func videoMetadataReadsDurationAndSize(_ fixture: MediaFixture) async throws {
        let asset = AVURLAsset(url: try fixture.url)
        let (duration, size) = await asset.videoMetadata(wantsVideo: true)

        #expect(try #require(duration, "\(fixture): no duration") > 0)
        let dimensions = try #require(size, "\(fixture): no size")
        #expect(dimensions.width > 0)
        #expect(dimensions.height > 0)
    }

    // `wantsVideo == false` (the audio path) reads only the duration — no track load, so size
    // comes back `nil` even for a file that carries a video track.
    @Test func audioModeReadsDurationOnly() async throws {
        let asset = AVURLAsset(url: try MediaFixture.h264.url)
        let (duration, size) = await asset.videoMetadata(wantsVideo: false)

        #expect(try #require(duration) > 0)
        #expect(size == nil)
    }

    // The thumbnailer's colour-tag read resolves the SDR fixtures non-HDR — an absent or SDR
    // transfer is never a spurious `true`.
    @Test(arguments: [MediaFixture.h264, .h265, .mpeg])
    func videoColorTagsReadSDRForAVFixtures(_ fixture: MediaFixture) async throws {
        let (gamma, _) = await AVURLAsset(url: try fixture.url).videoColorTags()
        #expect(!VideoColorTags.isHDR(gamma: gamma), "\(fixture): SDR fixture read as HDR (\(String(describing: gamma)))")
    }
}
