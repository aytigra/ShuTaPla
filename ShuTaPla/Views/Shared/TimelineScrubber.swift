//
//  TimelineScrubber.swift
//  ShuTaPla
//
//  The seek bar both timeline channels wear — the player's bottom bar for video, the audio
//  overlay's compact bar for the current track: elapsed time, a draggable track, total time.
//  It scrubs in absolute seconds and reports where the user let go; clamping the knob and
//  disabling itself on a channel with no timeline yet are its own business, so a caller only
//  hands it a position, a duration, and somewhere to seek.
//

import SwiftUI

struct TimelineScrubber: View {
    let position: TimeInterval
    let duration: TimeInterval
    /// The track's width, or `nil` to take what the row gives it. The overlay's transport is
    /// centred by equal flexible columns, so its scrubber must be a fixed size to stay put.
    var width: CGFloat?
    let seek: (TimeInterval) -> Void

    /// The slider's range. `Slider` needs a non-empty one, so a channel whose duration isn't
    /// known yet gets a hairline track — it is disabled at the same moment, so nothing moves on
    /// it. Pure metrics, so `nonisolated`: this and `knob` are the seek bar's test seam.
    nonisolated static func bounds(duration: TimeInterval) -> ClosedRange<Double> {
        0...max(duration, 0.1)
    }

    /// Where the knob sits: the position, held inside the track. Without a duration there is no
    /// timeline to place it on, so it rests at the start rather than pinning to the hairline's end.
    nonisolated static func knob(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(position, 0), duration)
    }

    var body: some View {
        HStack(spacing: 10) {
            timeLabel(position)

            Slider(
                value: Binding(
                    get: { Self.knob(position: position, duration: duration) },
                    set: { seek($0) }
                ),
                in: Self.bounds(duration: duration)
            )
            .frame(width: width)
            .disabled(duration <= 0)

            timeLabel(duration)
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> some View {
        Text(seconds.formattedDuration)
            .metadataCaption()
    }
}
