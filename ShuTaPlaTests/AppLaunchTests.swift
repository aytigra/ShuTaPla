//
//  AppLaunchTests.swift
//  ShuTaPlaTests
//
//  The app-hosted test target launches the real app as its host. `ShuTaPlaApp` detects that
//  from the process environment and skips the real store / `AppState` / window resume so a
//  test run can't relaunch the app into fullscreen and shuffle the user's desktops.
//

import Testing
@testable import ShuTaPla

@Suite struct AppLaunchTests {

    /// The presence of `XCTestConfigurationFilePath` marks the process as a test host.
    @Test func detectsTestHostFromEnvironment() {
        #expect(ShuTaPlaApp.isRunningAsTestHost(["XCTestConfigurationFilePath": "/tmp/x.plist"]))
    }

    /// A normal launch (no such key) is not a test host.
    @Test func treatsMissingKeyAsRealLaunch() {
        #expect(!ShuTaPlaApp.isRunningAsTestHost([:]))
        #expect(!ShuTaPlaApp.isRunningAsTestHost(["HOME": "/Users/x"]))
    }

    /// This very run is app-hosted, so the live detection must be true — confirming the env key
    /// is actually present and the guard engages (not just that the pure predicate works).
    @Test func liveProcessIsDetectedAsTestHost() {
        #expect(ShuTaPlaApp.isTestHost)
    }
}
