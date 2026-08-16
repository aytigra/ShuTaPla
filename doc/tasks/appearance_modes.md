# Appearance modes — Light / Dark / Auto

Give the app an explicit appearance setting (System, Light, Dark) and make the light appearance
actually hold up.

---

## What exists today

**The app already follows the system appearance.** There is no `NSRequiresAquaSystemAppearance` in the
build settings and nothing sets `NSApp.appearance`, so "Auto" is the current — and only — behaviour.
Switching the Mac to light already switches Shutapla.

What is missing is only the **override**: a way to run the app light on a dark Mac, or dark on a light
one. That is a setting, a stored value, and one line that applies it.

**The player is already pinned dark.** `playerOverlayPanel` ends with
`.environment(\.colorScheme, .dark)`, and the player surrounds are `Color.black`. The fullscreen
player's chrome is therefore already independent of the app-wide mode, which is the behaviour worth
keeping (media-first surfaces stay dark — QuickTime and IINA both do this).

**The light appearance holds up as it stands.** Checked by switching the system between light and dark
with the app running: no visual problems anywhere, and the AppKit `NSTextField`s inside the dark-pinned
panels (`RenameFileField`, `TagTokenField`'s `TokenTextField`) render dark along with the panel — so
SwiftUI does carry a pinned `\.colorScheme` through to a hosted `NSViewRepresentable`'s appearance,
and nothing needs pinning by hand.

---

## Design

### Storage: `UserDefaults`, not `GlobalSettings`

Appearance is view chrome, like `ManagerChrome`'s sidebar/inspector state (`UserDefaults`) and the
cache-pressure flag (`@AppStorage`). `GlobalSettings` holds *playback defaults that per-playlist
preferences fall back to* — appearance has no per-playlist counterpart, so it doesn't belong there.

This also avoids a `SchemaV11`, a migration stage, a migration test, and new golden hashes in
`SchemaVersionHashTests` for what is a pure UI preference. Cheap and consistent — but it is a
judgment call, so overrule it if you'd rather have every global preference in one model.

### Lever: `NSApp.appearance`

Apple's own guidance for an app-wide appearance:

```swift
NSApp.appearance = NSAppearance(named: .darkAqua)   // nil = follow the system
```

It propagates to "windows, views, panels, and popovers", which is what this app needs: the Manager is
an AppKit `NSSplitViewController` with an `NSToolbar` and an `NSTitlebarAccessoryViewController`, and
Settings is a **separate window**. `.preferredColorScheme` on `RootView` would reach neither.

### Pure core

```swift
nonisolated enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
    var displayName: String { … }
    var appearanceName: NSAppearance.Name? { … }   // nil for .system
}
```

Same shape as the other enums in `Models/Enums.swift`, and unit-testable without a view — matching how
this codebase already handles presentation logic.

---

## Steps

**Status:** done — all four steps.

**S1 · `AppearanceMode` + its tests.** ✅ The enum and its mapping, with a test suite. Pure, nothing
applied yet.

Lives in `ShuTaPla/App/AppearanceMode.swift` rather than `Models/Enums.swift`: `NSAppearance.Name`
would pull AppKit into the Foundation-only model enums, and the store plus the `apply` call from S2
belong beside it. Dropped `Codable` from the sketch — `UserDefaults` stores the raw string.
`AppearanceModeTests` covers the `.system → nil` hinge, that each override name resolves to a real
`NSAppearance`, and the raw values as the persisted form.

**S2 · Store and apply.** ✅ Read the stored mode at launch (`ShuTaPlaApp.init`, before the window exists,
so there's no flash of the wrong appearance) and apply it on change. One `apply` call site.

`AppearanceMode.defaultsKey` / `stored(in:)` / `apply()` sit beside the enum; `ShuTaPlaApp.init`
calls `AppearanceMode.stored().apply()` in the real-app path, past the test-host guard. The
separate observer the step imagined is not built: S3's picker binds `@AppStorage`, which is the
only writer, so applying on change is one `.onChange` beside it — a second one-line call site,
against a new observable type plus its environment plumbing. `stored(in:)` takes an injectable
`UserDefaults` (as `ManagerChrome` does) so the tests use a scratch suite.

**S3 · The Settings picker.** ✅ An "Appearance" section at the top of `SettingsView` — a segmented or
menu picker over `AppearanceMode.allCases`. Writes the stored value; S2's observer applies it.

Segmented, in a first section headed "Appearance" with the row labelled "Mode" — the
section-names-the-topic, row-names-the-control shape the other sections use. A footer states the
player exception. `pickerStorageIsWhatTheLaunchReadSees` pins the seam between what `@AppStorage`
writes and what `stored(in:)` reads. The Global settings list in `doc/features/playlists.md` gained
the setting.

**S4 · Spot-check the states a casual switch doesn't reveal.** ✅ Walked in Light; nothing reads
wrong, so no chrome changed. The everyday surfaces are already
confirmed good in both appearances; what a light/dark toggle won't have exercised is the conditional
chrome. Expect nothing, but look once, in Light:

- Hover and pressed washes — `ControlButtonStyle` (`Color.primary.opacity(0.13)`),
  `TitlebarControlButtonStyle` (`.quaternary.opacity(0.5)`).
- A selected row against the playback cursor: the 0.22 accent wash
  (`AppConstants.selectionHighlightOpacity`) beside `Color.playbackCursor`, a fixed sRGB purple picked
  against dark rows.
- `TagTokenField`'s chrome — `Color.secondary.opacity(0.08)` fill, `0.25` border — and a selected chip.
- The `SavedSearchesDropdown` panel, the cache banner, and the review/duplicate banners.
- The player, in every mode: black surrounds, dark overlays, dark controls bar, whatever the setting.

---

## Settled

**The fullscreen player stays dark in every mode.** It is already pinned that way, it reads correctly
under a light system appearance today, and light chrome around video is worse to watch. The setting
governs Manager, Welcome, and Settings; `playerOverlayPanel`'s pin stays.
