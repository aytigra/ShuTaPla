//
//  TimelineScrubberTests.swift
//  ShuTaPlaTests
//
//  The pure seam of the shared seek bar: the track it offers and where the knob sits on it.
//  A channel reports its position and duration independently — a duration arrives late, a
//  position can run past a stale one — so the bar has to stay drawable at every combination.
//

import Testing
import Foundation
@testable import ShuTaPla

@Suite struct TimelineScrubberTests {

    @Test func theKnobFollowsThePositionWithinTheDuration() {
        #expect(TimelineScrubber.knob(position: 30, duration: 120) == 30)
        #expect(TimelineScrubber.bounds(duration: 120) == 0...120)
    }

    /// A position reported against the previous file, or one past the end of a shortened stream,
    /// must not push the knob outside the track — `Slider` traps on a value out of its range.
    @Test func theKnobStaysInsideTheTrack() {
        #expect(TimelineScrubber.knob(position: 300, duration: 120) == 120)
        #expect(TimelineScrubber.knob(position: -5, duration: 120) == 0)
    }

    /// Before a duration is known the bar is disabled, but it still has to lay out: an empty
    /// range would trap, so the track keeps a hairline span with the knob resting at its start.
    @Test func anUnknownDurationLeavesADrawableEmptyTrack() {
        #expect(TimelineScrubber.bounds(duration: 0).lowerBound < TimelineScrubber.bounds(duration: 0).upperBound)
        #expect(TimelineScrubber.knob(position: 42, duration: 0) == 0)
        #expect(TimelineScrubber.bounds(duration: 0).contains(TimelineScrubber.knob(position: 42, duration: 0)))
    }
}
