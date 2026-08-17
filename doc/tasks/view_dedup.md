# View-layer dedup and conventions

Fold the duplicated view code together and write down the two conventions that keep it folded.
Quality only — no behaviour change is intended anywhere in this task.

**Status:** step 1 (D1 + D2) ✅ — the seven confirmation presenters are one `RootView` alert driven by
`PendingConfirmation.title` / `.message` / `.confirmLabel` (`PendingConfirmationWordingTests`), and
both rename-error channels are gone into `errorNotice`. D3 ✅ — one `TransportButton` behind all
eleven icon controls. D4 ✅ — one `TimelineScrubber` behind both seek bars. D5 ✅ — one `VolumeControl`
behind both volume sliders, closing step 2. D6 ✅ — one `.fileActions` behind row and cell, closing
step 3. D7 ✅ — one `.metadataCaption()`. D8 ✅ — `CenteredPlaceholder` and `StagePlaceholder`, closing
step 4. Step 5 ✅ — both conventions are in CLAUDE.md. **Task complete.**

Wording calls settled while folding, since one host means one phrasing per family:
- a single-file delete is titled by name in every context (`Move “a.mp4” to the Trash?`), so the
  player/audio deletes now match the Manager's, and the filename left the message
- `audioStrip` keeps the Manager's counted title and the shared `The original is moved to the Trash.`
  — the player's "playback resumes where it left off" clause is dropped, being untrue in Manager
- `playlistDelete` became an alert like the rest (it was the one `.confirmationDialog`), titled
  `Delete the playlist “X”?` with a plain `Delete` button
- `message` is non-optional: every family has one, so the `String?` in the sketch below bought nothing
- the per-case payload accessors lost their last production reader once the alert host took the whole
  enum, so they moved to `ShuTaPlaTests/PendingConfirmationTestSupport.swift` (six of the seven —
  `tagRemovalTag` had no reader at all), and `pruning(destroyedSearches:)` pattern-matches directly

---

## D1 · Confirmation alerts: seven copies of one modal

**The state side is already consolidated; only the presentation is duplicated.**
`PendingConfirmation` is a single enum with at most one case pending, and `confirmConfirmation()` is
one path. But seven view sites each re-derive a binding from a per-case accessor and repeat the same
button pair:

| Site | Confirmation |
|---|---|
| `PlaylistCenterView` | `managerDelete`, `audioStrip` |
| `PlayerView` | `playerDelete`, `audioStrip` |
| `AudioOverlay` | `audioDelete` |
| `PlaylistTagsView` | `tagRemoval` |
| `PlaylistSidebar` | `playlistDelete` (as a `.confirmationDialog`) |
| `FilterStrip` | `savedSearchDelete` |

Each is ~12 lines of the same skeleton: a `Binding` whose setter calls `cancelConfirmation()`, a
destructive button with `.keyboardShortcut(.defaultAction)`, a Cancel with `.cancelAction`, and a
message. `audioStrip` is presented **twice**, from two different views, with different message text.

**The codebase already argues for the fix.** `TagEditorView` explains why its failures go to the
app-wide `errorNotice` instead of a local alert: *"the `HotkeyRouter` can only hold the keyboard for a
modal it can see on `AppState`, and the editor is mounted in three places that would otherwise each
carry their own copy of the alert."* That reasoning applies verbatim to the confirmations.

**Fold to one host** — `RootView`, beside the two alerts it already presents — driven by a pure
extension on `PendingConfirmation`:

```swift
extension PendingConfirmation {
    var title: String          // "Move 3 files to the Trash?" — absorbs PlaylistCenterView's pluralization
    var message: String?
    var confirmLabel: String   // "Move to Trash" / "Remove Audio" / "Remove Tag" / "Delete"
}
```

Pure, `nonisolated`, unit-testable — the wording becomes the test surface, and it stops being possible
for two sites to word the same confirmation differently.

**Bonus:** `HotkeyRouter.hasBlockingConfirmation` hand-lists seven `AppState` fields. Fewer presenters
means fewer chances for that list to fall out of step with reality.

## D2 · Error alerts: two channels that do one job

`AppState` carries `playerRenameError` and `audioRenameError` alongside the app-wide `errorNotice`.
They exist only so the Visual Overlay and the audio overlay can each present a rename failure — the
same "Couldn't complete" alert, twice — and `LibraryContext` carries an `onRenameError` closure whose
only purpose is to pick which of the two fields to write.

Collapsing both into `errorNotice` (already hosted app-wide in `RootView`) removes two `AppState`
fields, two `.alert` blocks, one `LibraryContext` member, two closure literals at the context
construction sites, and two entries from `hasBlockingConfirmation`.

## D3 · Three private builders for one icon button

`ControlButtonStyle` is applied through three near-identical private helpers plus five inline copies:

- `PlaybackControlsBar` — `transportButton(_:action:)`, `loopButton`, `slideshowToggle`
- `AudioInlet` — `controlButton(_:action:)`, `loopButton`, `volumeButton`
- `AudioOverlay` — the two `trailingControls` buttons

Eleven call sites. They differ only in symbol, action, whether an active state tints them accent, and
a size (`PlaybackControlsBar` adds `.font(.title3)` and a 26×22 frame; `AudioInlet` takes the default).
One `TransportButton(title:systemImage:isActive:size:action:)` covers all of them.

Done. Notes on what the fold settled:
- three sizes, not two: `AudioOverlay`'s chrome shares the 26×22 cell with the bar but keeps its
  smaller `.callout.weight(.semibold)` glyph, so `.bar` and `.chrome` differ only in font
- the title doubles as tooltip and accessibility label (the convention below), which gives the eight
  bare transport glyphs the tooltips they never had
- an inactive button leaves the ambient foreground alone (`.foreground`) rather than pinning
  `.primary`, so the inlet's disabled Play still dims
- `TransportButton.Size` is `nonisolated`, matching `TitlebarControlButtonStyle.fillOpacity`: pure
  metrics are the layout's test seam (`TransportButtonSizeTests`)
- coverage added first: `PlaybackCoordinatorTests.loopTogglesOnTheVisualVideoChannel` — the loop
  toggle's `isActive` state had no test on the visual channel

## D4 · Two scrubbers

`PlaybackControlsBar.timeline` and `AudioOverlay.scrubber` are the same view: a leading time label, a
`Slider`, a trailing time label, all `.caption.monospacedDigit()` on `.secondary`. They differ in what
they bind to (absolute seconds vs. a 0…1 fraction) and the slider's width. One `TimelineScrubber`.

Done. Notes on what the fold settled:
- the scrubber scrubs in **seconds** on both channels: the overlay's fraction binding was the odd one
  out, so the coordinator gained `seekAudio(to:)` (the channel supplies its own playlist) and
  `seekAudio(toFraction:)` now delegates to it, staying for the inlet's drag-anywhere seek strip,
  which really does think in fractions
- the clamp and the disabled rule moved *into* the scrubber as `bounds(duration:)` / `knob(position:
  duration:)` — pure, `nonisolated`, the test seam (`TimelineScrubberTests`); both call sites had
  written the same `max(duration, 0.1)` / `duration <= 0` pair by hand
- with no duration the knob now rests at 0 instead of pinning to the hairline track's end (which the
  player bar did, on a slider that is disabled either way — visible only on a duration-less stream)
- the overlay's label spacing goes 8 → 10, the bar's value: one component, one spacing
- coverage added first: `PlaybackCoordinatorTests.audioSeekReachesTheLiveChannelOnly`, a
  `RecordingSeekEngine` in the audio slot — the channel-guard on the audio seek had no test

## D5 · Two volume sliders

`AudioVolumeControl` (in `AudioInlet.swift`) and `PlaybackControlsBar.volumeControl` are the same
control at two widths — same speaker glyph, same binding shape through the coordinator. Give
`AudioVolumeControl` a width and delete the copy.

Done. Notes on what the fold settled:
- it moved to `Views/Shared/VolumeControl.swift` and lost the `Audio` in its name: volume is a
  *playlist* preference, and the surviving copy is now worn by the video bar too — the name would
  have been wrong where it is used, and `Views/Shared/` is where D3 and D4 put their components
- `width` has no default, so neither host is the privileged one; the popover keeps 90, the bar 110
- the volume path was already covered by `PlaybackCoordinatorTests.setVolumePersistsAndClamps`
  (the exact get/set pair both bindings use), run green against the unchanged code before the move

## D6 · Row and cell are structural twins

`FileListRow` and `FileGalleryCell` both resolve a model from a `PersistentIdentifier`, draw one
presentation view, and then apply the *identical* tap-plus-context-menu block — including the same
three-line comment about why the tap gesture isn't stacked. One `.fileActions(file:playlist:onTap:…)`
modifier absorbs both the gesture and the `FileContextMenu`.

Done. Notes on what the fold settled:
- the five per-file closures travel as one `FileActions` value, so the modifier reads
  `.fileActions(actions, for: file, in: playlist)` rather than taking six parameters. Without that
  the duplication only moves: each call site would still spell out five closure forwards. It also
  shortens the layers in between — `FileListRow`, `FileGalleryCell` and `FileListSurface` each lose
  four parameters, and `FileCollectionView` states its five actions once instead of once per layout
- `FileContextMenu` lost its own file and its own four closures: it is now `private` beside the
  modifier, the only thing that reaches it, and reads the actions off the value
- `FileSelection.apply` — the click the modifier routes into — had no coverage at all
  (`actionTargets` did), so four cases went in first and ran green against the unchanged code:
  plain click replaces and moves the anchor, cmd toggles without disturbing the rest (and leaves
  the anchor put on deselect), shift unions the span either way, shift with no anchor selects one
- what is *not* folded: `renamingID` / `draftName` / `onCommitRename` / `onCancelRename` still ride
  the three layers separately. They are the inline-edit session and go to the presentation views,
  not to the menu — a second bundle would be the next reduction if it ever earns itself

## D7 · Metadata caption styling (minor)

`.font(.caption.monospacedDigit())` + `.foregroundStyle(.secondary)` appears at seven sites
(`FileRowView` ×2, `PlaybackControlsBar` ×2, `AudioOverlay` ×2, `PlaylistSettingsView`). A
`.metadataCaption()` extension states it once. Small, and partly absorbed by D4 anyway — do it last, or
skip it.

Done. Four sites survived D4 (`FileRowView` ×2, `PlaylistSettingsView`, and `TimelineScrubber`, which is
where the bar's and the overlay's four collapsed). Worth keeping despite the small count because the
style had already started to drift where it wasn't named: `GalleryCell`'s badge pill went to `.caption2`
on `.white` and `PlaylistRowBadge` to a bare `.monospacedDigit()`. Neither is folded in — the pill is
badge chrome over a thumbnail and the badge sits in a row title, so neither is the secondary metadata
this names.

## D8 · Placeholders (minor)

Four `ContentUnavailableView` uses and three hand-rolled centred glyph-and-text stacks
(`LibrarySurface.emptyFiles`, `TagSidebar`'s, `PlayerView.noFilesPlaceholder`). `LibrarySurface`
documents a real reason not to use `ContentUnavailableView` (it lays out against the window and jumps
to screen centre), which the other two share. One small `CenteredPlaceholder` for those three.

Done, but as **two** components, not one — the three named above don't form one family. Notes:
- `PlayerView.noFilesPlaceholder`'s twin isn't the other two: it is `CloudDownloadingPlaceholder`, which
  this item missed. Both are `ZStack { Color.black; VStack(spacing: 12) }` with a 48pt glyph over a
  `.headline` title in `.white.opacity(0.75)`, raised from adjacent branches of the same `PlayerView`
  `ZStack` under the same `.ignoresSafeArea().transition(.opacity)`. They are now one `StagePlaceholder`,
  and `CloudDownloadingPlaceholder` survives as the four-line wrapper naming the glyph rule its two
  callers share. Forcing all three into one component instead would have meant a mode parameter
  carrying foreground, glyph size, font *and* background — the modes would have been the component
- the remaining two (`LibrarySurface.emptyFiles`, `TagSidebar`'s) are `CenteredPlaceholder`, and their
  metrics were arbitrarily different: spacing 10 vs 8, glyph 40 vs 32, `.title3.weight(.semibold)` vs
  `.callout`. Standardized on `LibrarySurface`'s, so the tag sidebar's line is now larger and heavier —
  the same kind of call as D4's 8 → 10 label spacing. It is the only visible change in D7/D8
- `.multilineTextAlignment(.center)` and `.padding()` now apply to both (each had one of the two)
- `StagePlaceholder` elides its title in the middle on one line, which `CloudDownloadingPlaceholder`
  needed for a filename and the filter sentence never reaches
- **not tested, and there is nothing here to test**: no computed value, no branch — unlike D3's
  `TransportButton.Size` or D4's `bounds`/`knob`, these folds introduce no logic with a seam. Previews
  can't stand in either: this project can render none, because the preview harness fails to resolve
  `@rpath/libmpv.2.dylib` against the app target. That is why the codebase contains no `#Preview` at
  all. Verification is the build, the suite, and the running app
- not touched: `LibrarySurface`'s tag column still shows `ContentUnavailableView("No File Playing")`,
  inside the same overlay whose file column documents why that view is wrong there. Worth a look, but
  it is a behaviour question, not this task's dedup

---

## Conventions to write down

These belong in **CLAUDE.md's Code conventions**, not in this file — a task doc is temporary, and both
are rules for code that doesn't exist yet.

**Icon-only buttons carry a `Label`, not an `Image`.**

```swift
Button(action: …) { Label("Loop", systemImage: "repeat") }
    .labelStyle(.iconOnly)
    .help("Loop current file")
```

One string names the control and its tooltip, so they can't drift. `TitlebarControlButtonStyle` and
`CenterActionsBar` already do this; `PlaybackControlsBar`, `AudioInlet`, `AudioOverlay`,
`PlaylistTagsView`, `SavedSearchesDropdown` and `TagTokenField` use a bare `Image` instead. D3 converts
the transport ones; the rest follow the rule as they're touched.

**Modals are presented from one app-wide host, bound to `AppState` — never view-local.** This is
already forced by `HotkeyRouter`: its app-wide monitor must be able to *see* a modal to hold the
keyboard for it, and a view-local `@State` alert is invisible from there. CLAUDE.md states the
consequence ("register the modal's `AppState` flag in the router's `hasBlockingConfirmation`"); this
states the rule that avoids the problem. D1 and D2 make the codebase match it.

Both are in CLAUDE.md's Code conventions now, stated as rules for code rather than as a record of this
task: the modal one sits directly above the `HotkeyRouter` entry it explains, and the icon-button one
carries the accessibility half of the reason (a bare `Image` ships nameless to VoiceOver) alongside the
tooltip-drift one. Neither names the views that already comply or the ones that don't — the remaining
bare-`Image` sites (`PlaylistTagsView`, `SavedSearchesDropdown`, `TagTokenField`) follow the rule as
they're touched.

---

## Order

1. **D1 + D2** — the biggest reduction, and the only items with a pure core worth testing. Do them
   together: both end in `RootView` and both shorten `hasBlockingConfirmation`.
2. **D3, D4, D5** — the player-control cluster; one step, one area of the app.
3. **D6** — the row/cell twins.
4. **D7, D8** if they still look worth it afterwards.
5. The two convention entries into CLAUDE.md.

**Testing.** These are refactors, so per CLAUDE.md the behaviour must be covered *before* each one
moves: confirm `AppStateTests` / `HotkeyRouterTests` cover the confirmation request→confirm→cancel
paths and `hasBlockingConfirmation`, and `PlaybackCoordinatorTests` covers the transport/volume/seek
paths, adding any missing case first. The new `PendingConfirmation` wording extension gets its own
suite, written first.
