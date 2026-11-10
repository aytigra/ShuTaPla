# Shutapla

macOS media player. SwiftUI(macOS 27.2+) + SwiftData + mpv (libmpv).

## Key docs

- `doc/features.md` — feature-spec entry point: overview, Terminology glossary, and a map of the per-topic chapters in `doc/features/` (load only the chapter you need)
- `doc/architecture.md` — system design and architecture
- `doc/versioning.md` — SwiftData schema versioning: **read before changing any `@Model`** — a missed migration compiles fine and crashes the app at launch
- `doc/profiling.md` — recording and reading an Instruments trace (host Mac, SwiftUI template): **read before running any profiling tooling** — it is the first step, before invoking `record_trace.py`, `analyze_trace.py`, or `xctrace` — a guessed attach target or launch matches nothing (or the wrong instance) and the recorder silently captures no session

## Code conventions


**Modals are presented from one app-wide host bound to `AppState` — never view-local.** A `@State` alert inside a view is invisible to `HotkeyRouter`, whose app-wide monitor must be able to *see* a modal to hold the keyboard for it; a view mounted in several places would also carry one copy of the modal per mount, free to word itself differently in each. Raise the modal as a `WindowModal` case on `AppState.windowModals`, which shows one at a time, and present it once (`RootView`), deriving its wording from that state.

**`HotkeyRouter` owns bare keyboard input, not the responder chain.** Its app-wide `NSEvent` monitor intercepts keys before any SwiftUI `.alert`, so a modal's own button shortcuts never fire and bare keys leak to whatever the router routes them to. Present confirmations as `.alert` (with `.defaultAction`/`.cancelAction` buttons that handle `[enter]`/`[esc]` natively) and raise it through `AppState.windowModals`, which the router's `hasBlockingConfirmation` checks. An out-of-process system panel (`.fileImporter`) is raised as a `WindowModal` like the alerts, but its kind's `ownsKeys` is true: `keysBelongElsewhere`, checked before `hasBlockingConfirmation`, passes every bare key through while such a modal is shown.

**Fetch-based sequence accessors pair with `AppState.sequenceVersion`.** It is bumped on every membership or order mutation; views that read such an accessor read it too.

**The metadata merge calls `persistAndRefresh()` before the next object-returning `includePendingChanges = false` fetch.** It writes `duration`/`width`/`height`/`fileSizeBytes`/`fingerprint` onto the model, and such a fetch would discard those edits.

**General standard-type extensions live in `Extensions/`.**

## App data

Bundle ids: `com.aytigra.ShuTaPla.debug` (debug, sandboxed), `com.aytigra.ShuTaPla` (release). The thumbnail HEIC cache is `Application Support/<bundle id>/Thumbnails` inside the sandbox container.

## Testing

Project instances of the stack's test-crash patterns:

- **Orphaned context.** `ModelTests.swift` shows the container-holding form. `AppState.init` fetches (`AppStateModel.fetchOrCreate`), so even constructing `AppState` on an orphaned context traps.
- **Async work outliving the container.** Triggers: `AppState.select(_:)` launches an un-awaited rescan `updateTask`; an engine reaching natural EOF calls `advanceToNext()`, which walks `playlist.playbackSequence`; the slideshow timer. Set `appState.selectedPlaylist = x; appState.recomputeFilteredFiles()` instead of calling `select(x)`, or `await appState.updateTask?.value` before the body ends; always `defer { coordinator.shutdown() }`.
- **libmpv engine teardown race → `EXC_BAD_ACCESS` in `mpv_wait_event`.** A wakeup-scheduled event drain can land on the serial queue after `mpv_terminate_destroy`; `MPVClient.isTerminated` gates it, and tests still keep to the safe side. Use the window-free `AudioPlaybackEngine` (`vo=null`) for any mpv channel; never `VideoPlaybackEngine` in the test host (it needs a GL surface). Always `defer { shutdown() }`. Back fixtures with empty placeholder files (`Data()`): they fail to load (`END_FILE` reason `error`, not natural EOF), so they never trigger an `advanceToNext()` that touches models after teardown. When a test only needs the coordinator's synchronous bookkeeping, use an image playlist: the image engine has no libmpv.
- **Same-named model types.** `SchemaIndexMigrationTests` has the raw-SQLite helpers (`indexDDL`, `columns`, `rowCount`).
- **Closure in a `mutating` extension.** The target enables Approachable Concurrency; `Array.move(fromOffsets:toOffset:)` collects with a `for` loop for this reason.

**Committed media fixtures live in the `MediaFixture` enum (`ShuTaPlaTests/MediaTestSupport.swift`)**, backed by tiny files in `ShuTaPlaTests/Fixtures/` bundled into the test bundle as resources — each 64×64, ~1s, a few KB, with a silent audio track (so a decode never strains a timeout and the audio-stripping tests have a track to remove). Cases carry the codec: `.h264`/`.h265`/`.mpeg` (AVFoundation-decodable) and `.vp8`/`.vp9` webm (libmpv-only — the `MPVThumbnailer` fallback path); `.hdr` is a 10-bit VP9 tagged BT.2020 PQ (`video-params/gamma == "pq"`, the libmpv HDR path). Resolve one with `try fixture.url`, a throwing `Bundle(for:)` lookup; the enum is `CaseIterable`, so `@Test(arguments: MediaFixture.allCases)` sweeps every codec. `durationlessFixtureURL()` returns `noduration.h264` — a raw H.264 elementary stream libmpv loads but can never assign a duration — kept out of `MediaFixture` so the all-cases duration/HDR guards don't run against a duration-less file. These exercise the stateless extraction helpers (`ThumbnailService.renderThumbnail`, `MPVThumbnailer.frame`/`.duration`), which create and synchronously tear down their own short-lived mpv handles — no wakeup-scheduled drain, so the libmpv teardown race doesn't apply.

## Xcode project structure

This project uses Xcode **file system synchronized groups** (`PBXFileSystemSynchronizedRootGroup`). The following directories auto-sync with Xcode — files created on disk inside them appear in the Xcode project navigator automatically:

- `ShuTaPla/` — app source
- `ShuTaPlaTests/` — unit tests
- `ShuTaPlaUITests/` — UI tests
- `doc/` — documentation

**Always create new files inside one of these directories.** Files created outside them (e.g., at the project root) will NOT appear in Xcode unless manually added to `project.pbxproj`.
