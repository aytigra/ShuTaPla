//
//  TimeIntervalDurationTests.swift
//  ShuTaPlaTests
//
//  `TimeInterval.formattedDuration`: the compact running-time string shared by the
//  playback controls and the Manager's length indicators.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct TimeIntervalDurationTests {

    @Test(arguments: [
        (0.0, "0:00"),
        (5.0, "0:05"),
        (59.0, "0:59"),
        (60.0, "1:00"),
        (65.0, "1:05"),
        (600.0, "10:00"),
        (3599.0, "59:59"),     // just under an hour stays M:SS
        (3600.0, "1:00:00"),   // an hour widens to H:MM:SS
        (3661.0, "1:01:01"),
        (7384.0, "2:03:04"),
    ])
    func formats(_ seconds: TimeInterval, _ expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test func dropsFractionalSeconds() {
        #expect(TimeInterval(65.9).formattedDuration == "1:05")
    }

    @Test(arguments: [-1.0, -3600.0, .infinity, -.infinity, .nan])
    func clampsInvalidToZero(_ seconds: TimeInterval) {
        #expect(seconds.formattedDuration == "0:00")
    }
}
