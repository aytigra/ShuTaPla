//
//  TimeInterval+Duration.swift
//  ShuTaPla
//
//  Compact running-time formatting shared by the playback controls and the
//  Manager's file-list/gallery length indicators.
//

import Foundation

extension TimeInterval {
    /// A compact running time: `M:SS`, widening to `H:MM:SS` once the duration
    /// reaches an hour. Negative or non-finite values render as `0:00`.
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
