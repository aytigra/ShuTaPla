//
//  DisplaySleepBlocker.swift
//  ShuTaPla
//
//  Keeps the display awake while the player is playing. libmpv's embedded layer
//  doesn't manage power assertions for us, so the player owns one: while `isActive`,
//  a `ProcessInfo` activity with `.idleDisplaySleepDisabled` holds off the idle
//  screen dim/sleep; clearing it (a pause, or leaving Player mode) ends the activity
//  and lets the display sleep normally again.
//

import Foundation

@MainActor
final class DisplaySleepBlocker {
    private var token: NSObjectProtocol?

    /// Whether the display is currently being kept awake — exposed for tests.
    var isBlocking: Bool { token != nil }

    /// Arms or releases the assertion. Idempotent: repeated same-value writes are ignored.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? begin() : end()
        }
    }

    private func begin() {
        token = ProcessInfo.processInfo.beginActivity(
            options: .idleDisplaySleepDisabled,
            reason: "Playing media in Player mode"
        )
    }

    private func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }

    isolated deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
