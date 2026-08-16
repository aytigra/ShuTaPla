//
//  AppearanceModeTests.swift
//  ShuTaPlaTests
//
//  The app-wide appearance setting: its AppKit mapping and its persisted raw values.
//

import Testing
import AppKit
import SwiftUI
@testable import ShuTaPla

struct AppearanceModeTests {

    /// `.system` is the absence of an override — the one case that must map to `nil`, since that
    /// is what makes `NSApp.appearance` fall back to the system-wide setting.
    @Test func systemMapsToNoOverride() {
        #expect(AppearanceMode.system.appearanceName == nil)
        #expect(AppearanceMode.light.appearanceName == .aqua)
        #expect(AppearanceMode.dark.appearanceName == .darkAqua)
    }

    /// Every override names an appearance AppKit actually knows — a typo'd name would compile
    /// and then silently leave the app on the system appearance.
    @Test(arguments: AppearanceMode.allCases) func overrideNamesResolve(_ mode: AppearanceMode) {
        guard let name = mode.appearanceName else { return }   // `.system` has nothing to resolve
        #expect(NSAppearance(named: name) != nil)
    }

    /// The raw values are the persisted form; pinning them keeps a rename from silently
    /// resetting the stored preference to the default.
    @Test func rawValuesArePersistedIdentifiers() {
        #expect(AppearanceMode.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(AppearanceMode(rawValue: "dark") == .dark)
        #expect(AppearanceMode(rawValue: "sepia") == nil)
    }

    /// The picker lists every mode under a distinct label.
    @Test func displayNamesAreDistinct() {
        #expect(Set(AppearanceMode.allCases.map(\.displayName)).count == AppearanceMode.allCases.count)
    }

    /// A scratch defaults domain, so reading and writing the setting never touches the running
    /// app's own preference.
    private func withScratchDefaults(_ body: (UserDefaults) -> Void) throws {
        let name = "AppearanceModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    /// An unset key means a first launch, which must follow the Mac rather than pick a side.
    @Test func storedDefaultsToSystemWhenUnset() throws {
        try withScratchDefaults { defaults in
            #expect(AppearanceMode.stored(in: defaults) == .system)
        }
    }

    /// Every mode survives the round trip through the raw string the picker writes.
    @Test(arguments: AppearanceMode.allCases) func storedRoundTripsEveryMode(_ mode: AppearanceMode) throws {
        try withScratchDefaults { defaults in
            defaults.set(mode.rawValue, forKey: AppearanceMode.defaultsKey)
            #expect(AppearanceMode.stored(in: defaults) == mode)
        }
    }

    /// A string naming no case — a value left by an older build, or a hand-edited plist — falls
    /// back to `.system` instead of trapping on the optional.
    @Test func storedFallsBackOnUnknownValue() throws {
        try withScratchDefaults { defaults in
            defaults.set("sepia", forKey: AppearanceMode.defaultsKey)
            #expect(AppearanceMode.stored(in: defaults) == .system)
        }
    }

    /// The Settings picker writes through `@AppStorage`, the launch read comes back through
    /// `stored(in:)`: this pins that they agree on the encoding, so a choice survives a relaunch.
    @MainActor @Test func pickerStorageIsWhatTheLaunchReadSees() throws {
        try withScratchDefaults { defaults in
            let picker = AppStorage(wrappedValue: AppearanceMode.system, AppearanceMode.defaultsKey, store: defaults)
            picker.wrappedValue = .light
            #expect(AppearanceMode.stored(in: defaults) == .light)
        }
    }

    /// `apply()` installs the override on the application object, and `.system` clears it —
    /// `NSApplication.appearance` reports the override alone, so `nil` is AppKit following the
    /// system-wide setting.
    @MainActor @Test func applySetsAndClearsTheApplicationOverride() {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }

        AppearanceMode.dark.apply()
        #expect(NSApplication.shared.appearance?.name == .darkAqua)

        AppearanceMode.system.apply()
        #expect(NSApplication.shared.appearance == nil)
    }
}
