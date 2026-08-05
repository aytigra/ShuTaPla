//
//  ManagerChromeMemoryTests.swift
//  ShuTaPlaTests
//
//  How the Manager remembers which of its side panes were showing. `ManagerChrome` is `@State` on a
//  view that leaves the tree whenever Player mode takes over, so a second instance built over the
//  same defaults is the real scenario these tests describe — a mode switch and a relaunch reach the
//  restored state by the same route.
//

import Testing
import Foundation
import Synchronization
@testable import ShuTaPla

@MainActor @Suite struct ManagerChromeMemoryTests {

    /// A defaults domain of its own per test, so a stored layout can't leak into the next test or
    /// into the developer's own app defaults.
    func makeDefaults() throws -> UserDefaults {
        let suite = "ManagerChromeMemoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFirstLaunchShowsBothPanes() throws {
        // Nothing stored yet. The inspector's default is the one that can't come from a plain
        // `bool(forKey:)`, which reads a missing key as `false` — as "hidden".
        let chrome = ManagerChrome(defaults: try makeDefaults())
        #expect(chrome.sidebarCollapsed == false)
        #expect(chrome.inspectorVisible == true)
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func eitherPanesLastStateComesBackOnTheNextChrome(
        _ sidebarCollapsed: Bool, _ inspectorVisible: Bool
    ) throws {
        // Every combination, so neither flag can be restored from the other's key and re-showing a
        // pane is remembered as surely as hiding it.
        let defaults = try makeDefaults()
        let chrome = ManagerChrome(defaults: defaults)
        chrome.sidebarCollapsed = sidebarCollapsed
        chrome.inspectorVisible = inspectorVisible

        let restored = ManagerChrome(defaults: defaults)
        #expect(restored.sidebarCollapsed == sidebarCollapsed)
        #expect(restored.inspectorVisible == inspectorVisible)
    }

    @Test(arguments: [true, false])
    func aRememberedPaneStillNotifiesObservers(_ sidebar: Bool) throws {
        // What the panes are actually driven by: `ManagerSplitViewController.observeChrome` re-applies
        // the collapse from a `withObservationTracking` over these two properties. Persisting them
        // through a `didSet` puts an accessor on a property the `@Observable` macro also rewrites, so
        // this pins that the macro still tracks them — untracked, the toolbar toggles would set the
        // flag and nothing on screen would move.
        let chrome = ManagerChrome(defaults: try makeDefaults())
        // `onChange` is `@Sendable`, so the flag it raises has to be too.
        let notified = Mutex(false)
        withObservationTracking {
            _ = chrome.sidebarCollapsed
            _ = chrome.inspectorVisible
        } onChange: {
            notified.withLock { $0 = true }
        }

        if sidebar { chrome.sidebarCollapsed.toggle() } else { chrome.inspectorVisible.toggle() }
        #expect(notified.withLock { $0 })
    }

    @Test func tagManagementModeIsNotRemembered() throws {
        // A task you are in the middle of, not a layout preference — relaunching into it would be
        // surprising, so it stays with the instance.
        let defaults = try makeDefaults()
        ManagerChrome(defaults: defaults).managingTags = true
        #expect(ManagerChrome(defaults: defaults).managingTags == false)
    }
}
