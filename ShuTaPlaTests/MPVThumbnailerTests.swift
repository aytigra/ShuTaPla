//
//  MPVThumbnailerTests.swift
//  ShuTaPlaTests
//
//  The metadata probe's pure return decision (`probeSettled`). The end-to-end stall bound is
//  covered by `VideoDurationTests/durationlessFileReturnsBeforeDeadline` over a real duration-less
//  fixture; this exercises the decision table directly, without mpv or the wall clock.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct MPVThumbnailerTests {

    // `probeSettled` decides when the metadata probe can stop pumping: once the duration is known
    // (the demuxer dimensions land with or before it, and the list probe reads no HDR), and
    // otherwise only once the settle grace since `FILE_LOADED` has elapsed — so a file that never
    // reports a duration returns at the grace instead of stalling to the full deadline.
    @Test(arguments: [
        // duration known → settled immediately, grace irrelevant, for audio (no track) and video.
        (TimeInterval?.some(1), Int?.none, false, true),
        (1, 1920, false, true),
        // no duration yet: hold before the grace, return after — not a 15 s stall.
        (nil, 1920, false, false),
        (nil, 1920, true, true),
    ] as [(TimeInterval?, Int?, Bool, Bool)])
    func probeSettles(duration: TimeInterval?, width: Int?, graceElapsed: Bool, expected: Bool) {
        let metadata = MediaMetadata(duration: duration, width: width)
        #expect(MPVThumbnailer.probeSettled(metadata, graceElapsed: graceElapsed) == expected)
    }
}
