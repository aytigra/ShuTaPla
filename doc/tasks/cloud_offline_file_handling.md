# Task — Cloud / offline file handling

Give playlist files live iCloud/offline awareness: a per-file status (local / in cloud /
downloading) that updates as the system evicts and fetches files, on-demand download when playback
reaches an evicted file, prefetch of the next files ahead of playback, and status indicators in the
list, gallery, and audio transport.

## What already exists (build on it, don't duplicate)

- **`CloudStatus`** — `Models/Enums.swift`: `.local`, `.inCloud`, `.downloading`. Runtime-only, never
  persisted.
- **`PlaylistFile.cloudStatus`** — a `@Transient` property (`Models/PlaylistFile.swift`). It lives on
  the model but stays out of the store and out of schema versioning. SwiftData's `@Model` macro wraps
  only *persisted* stored properties in the Observation registrar and leaves a `@Transient` stored
  property un-tracked, so `cloudStatus` is a computed property backed by a `@Transient` store whose
  accessors are hand-routed through the model's `_$observationRegistrar` (`access` / `withMutation`).
  Writing it on the main actor then re-renders any view reading it — no schema change, no migration.
  (Verified by spike: a plain `@Transient var` mutates invisibly to `withObservationTracking`; the
  registrar-routed one wakes it. The same fix repairs the Step-4 badge readers.)
- **Scan-time classification** — `FileSystemService.enumerateMedia(in:)` fetches the ubiquitous URL
  resource keys and maps them through `cloudStatus(from:)` into every `ScannedFile`; the reconcile
  path copies that onto `file.cloudStatus`.

Today the status is set **once at scan time** and never changes. This task adds the live feed,
downloads, prefetch, UI, and playback handling on top. There is no cloud UI yet — `cloudStatus` is
written but never read.

## Isolation & concurrency ground rules (project is Swift 6, `MainActor` default isolation)

- `NSMetadataQuery` and `NSMetadataItem` are non-`Sendable` and run-loop-bound. Create, start, stop,
  and read every query on the main actor; never hand one across an isolation boundary.
- The status-classification helper is `nonisolated static` (pure, no isolation), shared by the scan
  and the live query.
- Under `MainActor` default isolation a plain `nonisolated` member still runs on the caller's actor;
  to move work off the main actor use `@concurrent` (as `MediaMetadataService.extract` does). Only the
  download request is a candidate for that, and only if it proves to block.

## Architecture

`CloudFileService` — `@MainActor @Observable final class`, modeled on `MediaMetadataService`.
Constructed in `ShuTaPlaApp` and injected with `.environment(cloudFileService)`; views read it with
`@Environment(CloudFileService.self)`. It owns the live queries, exposes a single download entry
point, and writes `cloudStatus` back onto the models.

`PlaybackCoordinator` holds an injected reference to `CloudFileService` (alongside `folderAccess`,
`globalSettings`) and drives prefetch and per-file download from its existing file-change choke point.

## Implementation steps (one at a time; each ships testable)

### Step 0 — Observe current missing-file playback behavior ✅

Before writing any skip logic, drive a test that hands the engine a file whose URL is gone and record
what happens. The mpv engine only calls `advanceToNext()` on natural EOF (`case .endFile(.eof)`); a
load error (`END_FILE` reason `error`) currently hits `case .endFile: break`. Confirm whether a
missing file stalls or already advances. The result determines whether Step 6's silent skip is new
behavior or an extension of existing behavior. **No code change in this step** — it's the experiment
that scopes Step 6.

**Observed (test `PlaybackEngineTests.loadErrorStallsWithoutAdvancing`, green on unchanged code):**
an mpv load failure surfaces as `.endFile(.error)`, which the engine ignores — the channel stays
anchored on the unloadable file with nothing playing and never skips forward. `url(for:)` appends
`relativePath` with **no existence check**, so a missing file *is* handed to mpv and fails this way.
**Conclusion:** Step 6's silent skip is new behavior to add, not an existing path to extend.

### Step 1 — Shared status classification ✅

Extract the `URLResourceValues → CloudStatus` mapping out of `FileSystemService.cloudStatus(from:)`
into a shared `nonisolated static` helper (its own file under `Services/`, or a `CloudStatus`
extension) that both the scan and the live query call, so they cannot drift. Add a sibling that maps
an `NSMetadataItem`'s ubiquitous values (`NSMetadataUbiquitousItemDownloadingStatusKey`,
`NSMetadataUbiquitousItemIsDownloadingKey`) to the same `CloudStatus`. `FileSystemService` calls the
`URLResourceValues` form; `CloudFileService` calls the metadata-item form.

*Test:* parameterized status mapping — evicted/placeholder → `.inCloud`, actively fetching →
`.downloading`, present/non-ubiquitous → `.local` — driven directly with synthesized values for both
helper forms.

**Done.** `Services/CloudStatus+Classification.swift` — a `nonisolated extension CloudStatus` with a
pure `classify(isUbiquitous:isDownloading:isNotDownloaded:)` core and two adapters, `from(URLResourceValues?)`
and `from(NSMetadataItem)`, both funneling into it. `FileSystemService` now calls `CloudStatus.from(values)`;
its private `cloudStatus(from:)` is gone. The OS-type adapters read read-only system values a test can't
synthesize, so `CloudStatusTests` parameterizes the full truth table on the pure core they both delegate
to (6 cases, green). Existing `FileSystemServiceTests` still green — refactor preserved behavior.

### Step 2 — `CloudFileService` live status feed ✅

- One `NSMetadataQuery` per live channel (Visual, Audio), so two playlists in different folders both
  stay live. Key the queries by channel; each is scoped to its playlist's folder
  (`searchScopes = [folderURL]`), predicated on the media file extensions, gathering the ubiquitous
  downloading keys.
- A channel's query starts when a playlist goes live on it and stops (or rescopes to the new folder)
  when that channel's playlist changes or the channel stops.
- Observe `.NSMetadataQueryDidFinishGathering` and `.NSMetadataQueryDidUpdate` on the main actor.
  In the handler, bracket result reads with `disableUpdates()` / `enableUpdates()` for a stable
  snapshot, map each changed item to its `PlaylistFile` by path (relative to the folder), classify
  via the Step 1 metadata-item helper, and assign `file.cloudStatus`.
- Inject the service in `ShuTaPlaApp` next to `metadataService` / `thumbnailService`.

Give the classification-and-apply core a seam (a protocol or closure for the status source) so tests
drive status transitions without a live iCloud account or a real query.

*Test:* feeding status events through the seam flips `file.cloudStatus` on the matching model and
leaves others unchanged.

**Done.** `Services/CloudFileService.swift` — a `@MainActor @Observable final class` keying one
`NSMetadataQuery` `Monitor` per `Channel` (`.visual` / `.audio`). `beginMonitoring(_:folderURL:on:)`
scopes a query to the playlist folder (match-all predicate; scope does the folder-narrowing),
observes `DidFinishGathering`/`DidUpdate` on the main queue, and — under `disableUpdates()` /
`enableUpdates()` — maps each result item to a `CloudStatusUpdate` (relative path via the now-shared
`FileSystemService.relativePath(of:under:)`, status via the Step 1 `CloudStatus.from(NSMetadataItem)`)
and folds them onto `playlist.files` through the pure `apply(_:to:)` core. `endMonitoring(on:)` stops
the query and removes its observers. The coordinator holds it (injected, default-constructed for
tests) and drives the lifecycle from the channel claim/release points (`startVisual`/`startAudio`
begin; `stopVisual`/`stopAudio`/`shutdown` end); `AppState` owns the instance and `ShuTaPlaApp`
injects it into the environment. `CloudStatusUpdate` is the test seam: `CloudFileServiceTests` drives
`apply` directly (match / no-match / repeat-supersede) with no live query — 3 tests green, full
`PlaybackCoordinatorTests` (42) still green, so the lifecycle wiring neither regressed nor trapped.

### Step 3 — On-demand download ✅

`func requestDownload(_ file: PlaylistFile)` on `CloudFileService` — the one entry point for both
on-demand and prefetch. It resolves the file's URL through the folder's scoped-access session
(`ScopedFolderAccess` / `BookmarkService.withScopedAccess`) and calls
`FileManager.default.startDownloadingUbiquitousItem(at:)`. It requests, never waits; the live feed
reports the resulting `.downloading` → `.local` transition. The call returns immediately, so it runs
on the main actor; move it behind a `@concurrent` helper only if it measurably blocks. Route the
actual `FileManager` call through an injectable requester so tests assert requests without touching
iCloud.

*Test:* `requestDownload` issues exactly one request for the given file (mock requester).

**Done.** `CloudFileService.requestDownload(_:)` — resolves the file's playlist-folder bookmark via
`BookmarkService.withScopedAccess(to:)`, appends `relativePath`, and hands the resulting URL to an
injected `requester: (URL) throws -> Void` (default `FileManager.default.startDownloadingUbiquitousItem(at:)`).
Request-and-forget on the main actor; the live feed reports the ensuing `.downloading` → `.local`
transition. A file with no playlist or an unresolvable folder (`try?`) is a silent no-op. The
`requester` seam lets `CloudFileServiceTests` capture the request without iCloud — 2 tests green
(one request for the named file; no-op for an orphan file), full `CloudFileServiceTests` (5) green,
navigator clean.

### Step 4 — `CloudStatusBadge` and wiring ✅

**Done.** `CloudStatusBadge` (in `Views/Shared/`) renders the semantic glyph for a `CloudStatus`
— `.inCloud` → `icloud`, `.downloading` → `icloud.and.arrow.down`, `.local` → nothing — with a
matching `.accessibilityLabel`. The glyph/label mapping lives on `CloudStatus` itself as the pure,
`nonisolated` `badgeSymbol` / `badgeAccessibilityLabel`, so it's tested without a view and the
gallery reads it directly. Wired in all three spots alongside the on-disk size:
- **List** — a `.secondary` caption glyph before the size column in `FileRowView.metadataColumns`.
- **Gallery** — `GalleryCell`'s `badge(_:)` pill chrome was extracted into a generic `pill(_:)`;
  the bottom-leading overlay now pairs a cloud-glyph pill (shown only when `badgeSymbol != nil`)
  beside the size pill.
- **Audio channel** — the leading edge of the shared `AudioTransport`, reading
  `appState.currentAudioFile?.cloudStatus`, so it appears in the sidebar inlet and the player overlay.

Chose the plain glyph over a determinate `ProgressView` for `.downloading` — plumbing the percent
key through would need another `@Transient` and query attribute for a marginal readout; the plan
allows the glyph fallback.

*Test:* `badgeSymbolMapsEachStatus` (parameterized, in `CloudStatusTests`) asserts the glyph and
label-presence for each status; the badge is a pure function of the passed status, and the model
reactivity (a `cloudStatus` write re-rendering readers) is the registrar-routed Observation from
Step 1, so there's no view-inspection test. Build clean; CloudStatusTests 9/9 green; navigator clean.

A small `CloudStatusBadge` view driven by a file's `cloudStatus`:
- `.inCloud` → an "in the cloud" glyph (`icloud`),
- `.downloading` → a downloading indicator (`icloud.and.arrow.down`, or the progress form below),
- `.local` → renders nothing.

Place it **alongside the on-disk size**, since cloud state and size are conceptually paired:
- **List** — next to the size column in `FileRowView.metadataColumns`.
- **Gallery** — next to the size badge (`GalleryCell` bottom-leading corner overlay), not a new corner.
- **Audio channel** — in the **Audio Transport** (the shared control both the Audio Inlet and the
  Audio Overlay render), so it shows in Manager mode and the overlay from one place.

The badge is a status indicator, not a control: give it an `.accessibilityLabel` describing the state
and use the semantic SF Symbols above, so Task 20 needs no rework here.

When the file is `.downloading`, the badge may show real downloaded-vs-total progress
(`NSMetadataUbiquitousItemPercentDownloadedKey` / the `URLResourceValues` percent key) via a
determinate `ProgressView`; fall back to the plain glyph if wiring the percentage through is fiddly.

*Test:* the `cloudStatus → glyph/visibility` mapping (pure), and that changing a model's `cloudStatus`
updates the rendered badge.

### Step 5 — Prefetch ahead of playback ✅

Done. `setCurrentFile(_:on:)` in `PlaybackCoordinator+Persistence.swift` — the one point every switch
(Play, jump, engine advance) routes through — now walks the next `AppConstants.cloudPrefetchCount`
(3) files ahead in playback order and calls `cloudFileService.requestDownload` on each not-yet-`.local`
one. The selection is a pure `static PlaybackCoordinator.prefetchTargets(after:in:count:)`: it wraps
past the end the way playback does, never returns the current file, and never repeats when the
sequence is shorter than the horizon — unit-tested apart from the coordinator's download side effect.

Tests (in `PlaybackCoordinatorTests`, reusing its container/folder/playlist fixtures):
`prefetchTargetsWalksAheadSkippingLocalsAndWrapping` covers the pure selector (ahead, skip-local,
wrap, over-count, degenerate); `fileSwitchPrefetchesTheNextNonLocalFiles` drives the choke point
directly (`setCurrentFile`, no engine/query) through a capturing `CloudFileService(requester:)` and
asserts exactly the two evicted files are requested in order. Build clean, both green, 0 navigator
warnings.

In `PlaybackCoordinator`, on every file switch, ask `CloudFileService` to `requestDownload` the next
**N** files in playback order, skipping any already `.local`. N is one small named constant for all
media types (start at 2–3). The switch choke point is `setCurrentFile(_:on:)` in
`PlaybackCoordinator+Persistence.swift` — every Play, jump, and engine-reported advance routes through
it. Walk the sequence forward with the existing `cyclicSuccessor` over `playlist.playbackFiles`.

Put the "next N not-yet-local files in playback order" logic in a pure function so it's testable apart
from the coordinator.

*Test:* the selector returns exactly the next N files skipping locals (pure); a file switch issues
download requests for exactly those files (mock service).

### Step 6 — Playback integration: evicted vs missing

`cloudStatus` and on-disk presence discriminate the two unavailable cases, split by *where* each is
handled: a **missing** file is skipped by the coordinator before any engine touches it; an **evicted**
file is handed to the engine, which shows a placeholder until the bytes arrive. Nothing reads the file
before the engine — the coordinator's `url(for:)` only builds a path (Step 0) — so the coordinator is
the right place for the pre-load skip, and it unifies the behavior across all three engines instead of
being an mpv-only load-error quirk.

- **Missing** (`.local`, but gone from disk before a rescan pruned it): skipped to the next available
  file. An evicted file still exists on disk as a placeholder stub, so `FileManager.fileExists` returns
  true for it — only a `.local` file absent from disk is "missing." The skip is a shared pure "next
  available" selector applied at the one point the next file is chosen, so it covers coordinator-
  initiated loads (start / jump / reconcile) and engine advances (EOF, slideshow, next / prev) alike.
- **Evicted** (`.inCloud` / `.downloading`): handed to the engine normally — the cursor moves like any
  other file, so prev/next, the playback keys, and `setCurrentFile` are untouched. At load the engine
  checks readiness (`file.cloudStatus != .local`); if not ready it holds the file as pending, shows the
  placeholder, and asks for the download (`PlaybackSource.requestDownload`). It watches that file's
  `cloudStatus` (registrar-routed, so `withObservationTracking` sees the flip) and performs the real
  load in place when it becomes `.local`, clearing pending. The live feed / `CloudFileService` stays
  the sole source of status; arrival-detection lives in the engine.

For **video/audio** the wait is implicit: an evicted file never loads, so it never reaches EOF and the
channel rests on the placeholder until the bytes arrive. For **images under slideshow** the timer keeps
its cadence and moves on after the interval whether or not the file downloaded — existing behavior, no
anti-skip rule. A user Next/Prev during a wait retargets normally; an evicted new target takes the same
placeholder path.

Sub-steps (each ships testable):

- **6a — Missing-file skip** (coordinator) ✅. Done. `PlaybackCoordinator.availableFile(in:from:forward:includeStart:isAvailable:)`
  (a pure `static` in `+Persistence.swift`) walks the sequence in playback order (wrapping) to the
  first file the injected predicate accepts — `forward` picks direction, `includeStart` decides
  whether `start` itself is a candidate. The coordinator's predicate is `isAvailable(_:)`: an evicted
  file is a valid target (6b placeholders it), a present local file is, and only a `.local` file
  absent from disk (`FileManager.fileExists` under the live folder's scoped access) is not; an
  unresolvable folder isn't treated as missing. Wired into `fileAfter` / `fileBefore` (advance /
  previous), `startFile` (start), and `jump` (jump / reconcile) — every point the next file is chosen.
  `cyclicSuccessor` / `cyclicPredecessor` stay (still used by the engine-test mock source and their
  own suite). Tests in `PlaybackCoordinatorTests`: `availableFileSkipsUnavailableAndWraps` drives the
  pure selector with a synthetic predicate (forward/backward, include/exclude start, wrap,
  all-unavailable → nil, start-only-excluded → nil); `advanceSkipsAMissingLocalFile` seeds a real
  playlist whose middle file is never written to disk and asserts `fileAfter` / `fileBefore` skip it
  (observed red first on the unchanged code, which returned the missing file). Build clean, full
  `PlaybackCoordinatorTests` (47) green, 0 navigator warnings.

- **6b — Evicted placeholder** (engines) ✅. Done. A shared `CloudLoadGate` (`Engines/CloudLoadGate.swift`,
  `@MainActor @Observable`) holds the evicted-load pending-state for all three channels: the two mpv
  engines and the image engine each own a `let cloudLoad = CloudLoadGate()` and, on load, hand it the
  file plus the byte-touching load as a closure (`startFile` / `decode`). A `.local` file loads at once;
  an evicted one is held pending (`pendingFile` set, exposed for 6c's placeholder), its download requested
  via the new `PlaybackSource.requestDownload` seam (coordinator → `CloudFileService.requestDownload`),
  and a one-shot `withObservationTracking` on `cloudStatus` re-arms until the flip to `.local`, then runs
  the deferred load and clears pending. `stop()` calls `cloudLoad.cancel()`. The engines reset transient
  state (time / size / playing / transform) up front so nothing stale lingers while pending. This rests on
  `cloudStatus` being registrar-routed for Observation — see the terminology note; a spike proved a plain
  `@Transient var` does not wake `withObservationTracking`, and the fix also repairs the Step-4 badges.
  *Tests:* `CloudLoadGateTests` — `localFileLoadsAtOnce`, `evictedFileHoldsPendingThenLoadsOnArrival`
  (observed red first with the plain `@Transient`, green after the registrar routing), `cancelDropsPendingWait`;
  `PlaybackEngineTests` mock source records `requestDownload`. Build clean, full suite green, 0 navigator warnings.

- **6c — View placeholders** ✅. Done. The visual channel shows a full-stage downloading placeholder
  while its engine holds an evicted load; the audio channel already surfaces the state through its
  Step-4 badge, so no audio-transport change was needed.
  - `PlaybackCoordinator.visualCloudPendingFile` (`+Controls.swift`) — the evicted file the active
    visual engine is holding, `imageEngine.cloudLoad.pendingFile ?? videoEngine?.cloudLoad.pendingFile`.
    Only one visual engine is ever live (starting a channel stops and clears the other), so the first
    non-`nil` gate is the active one; the audio engine's gate is deliberately excluded. `PlayerView`
    reads it and overlays `downloadingPlaceholder(_:)` (glyph tracking the file's live `cloudStatus` →
    `icloud` / `icloud.and.arrow.down`, the file name, a small spinner), mirroring `noFilesPlaceholder`
    and fading in/out with the existing `.animation(…, value:)` chain. This covers both video (the mpv
    render surface stays black while pending) and image (its engine leaves `currentImage` nil) from one
    place, rather than editing the two leaf player views — `VideoPlayerView` is an `NSViewRepresentable`
    with no overlay of its own, and `PlayerView` already branches the two and hosts the sibling
    `noFilesPlaceholder`.
  - **Audio** — `AudioTransport`'s leading `CloudStatusBadge(status: currentAudioFile?.cloudStatus)`
    (Step 4) already is the audio downloading indicator: while an evicted track is pending it *is* the
    current file, so the badge shows `icloud` / `icloud.and.arrow.down` and, now that `cloudStatus` is
    registrar-routed (Step 1 spike), re-renders the moment the live feed flips it to `.local`.
  - *Tests:* `PlaybackCoordinatorTests.visualCloudPendingFileTracksTheVisualEngineGate` — an evicted
    image load holds pending (never decoded, no libmpv → trap-safe) and the coordinator surfaces it,
    then `stop()` clears it; the pending-state set/clear/arrival itself is covered by `CloudLoadGateTests`.
    The placeholder is a pure function of `pendingFile != nil` (view markup, no inspection test, as with
    the Step-4 badge). Build clean, full `PlaybackCoordinatorTests` (49) + `CloudLoadGateTests` (3) green,
    0 navigator warnings.

## Testing notes

Follow the project's "test the stateless/pure core" guidance: the status classification, the prefetch
selection, the "next available" selection, and the badge glyph mapping are all pure and unit-tested
directly, no live iCloud account. The stateful pieces (`CloudFileService` apply, coordinator
integration) are driven through injected status-source and download-requester seams.

Trap-awareness (per CLAUDE.md): keep coordinator/routing tests on an **image** playlist to avoid
libmpv teardown (trap class 3); set `cloudStatus` and current-file state directly rather than through
task-launching paths that touch SwiftData after teardown (trap class 2); never run a real
`NSMetadataQuery` in the test host — inject a mock status source. Review new tests against the trap
classes before running.

## Residual questions

- **Placeholder upper bound.** Settled: the video/audio channel rests on the downloading placeholder
  **indefinitely** — no give-up-and-skip timeout. A user Next/Prev retargets normally.
- **Glyph choice** for `.inCloud` vs `.downloading`, and whether the download-progress percentage is
  worth its wiring — settle alongside Task 20 so the accessibility labels are written once.
