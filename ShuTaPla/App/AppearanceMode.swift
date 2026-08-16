//
//  AppearanceMode.swift
//  ShuTaPla
//
//  The app-wide light/dark setting. `nonisolated` so it can be read from any isolation
//  context, like the other shared enumerations.
//

import AppKit

/// Which appearance the app runs in, overriding the system-wide setting.
///
/// The raw values are the persisted form, so renaming one silently resets the user's choice.
nonisolated enum AppearanceMode: String, Sendable, CaseIterable {
    case system
    case light
    case dark

    /// Capitalized human-facing name (the Settings picker).
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance to assign to `NSApp.appearance`. `nil` means "no override" — AppKit
    /// then follows the system-wide setting, which is what `.system` asks for.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// `UserDefaults` key for the setting, written by the Settings picker's `@AppStorage`
    /// binding and read back here at launch. Appearance is view chrome like the Manager's pane
    /// state, not a playback default, so it lives in defaults rather than `GlobalSettings` —
    /// which keeps it out of the SwiftData schema and its migrations.
    static let defaultsKey = "appearanceMode"

    /// The stored setting, falling back to `.system` when unset — a first launch follows the
    /// Mac — or when the stored string names no case.
    static func stored(in defaults: UserDefaults = .standard) -> AppearanceMode {
        defaults.string(forKey: defaultsKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    /// Overrides the appearance of every window, panel, and popover the app owns, including the
    /// AppKit-hosted Manager and the separate Settings window — neither of which a
    /// `.preferredColorScheme` on the SwiftUI root would reach. The fullscreen player is
    /// unaffected in any mode: `playerOverlayPanel` pins its own `\.colorScheme` to `.dark`.
    @MainActor func apply() {
        NSApplication.shared.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}
