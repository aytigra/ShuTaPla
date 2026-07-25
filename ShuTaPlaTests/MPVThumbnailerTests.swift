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
    // and the colour tag is resolved (or the file has no video track, so it never gets one), and
    // otherwise only once the settle grace since `FILE_LOADED` has elapsed — so a file that never
    // reports a duration, or whose gamma never settles, returns at the grace instead of stalling
    // to the full deadline.
    @Test(arguments: [
        // duration + no video track (audio) → settled immediately, grace irrelevant.
        (TimeInterval?.some(1), Int?.none, String?.none, false, true),
        // duration + colour tag resolved → settled immediately.
        (1, 1920, "pq", false, true),
        // duration but gamma not yet: hold before the grace, return after.
        (1, 1920, nil, false, false),
        (1, 1920, nil, true, true),
        // no duration ever: hold before the grace, return after — not a 15 s stall.
        (nil, 1920, "bt.1886", false, false),
        (nil, 1920, "bt.1886", true, true),
    ] as [(TimeInterval?, Int?, String?, Bool, Bool)])
    func probeSettles(duration: TimeInterval?, width: Int?, gamma: String?, graceElapsed: Bool, expected: Bool) {
        let metadata = MediaMetadata(duration: duration, width: width, hdrGamma: gamma)
        #expect(MPVThumbnailer.probeSettled(metadata, graceElapsed: graceElapsed) == expected)
    }
}
