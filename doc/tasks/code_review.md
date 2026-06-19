# Code review — full codebase (xhigh, recall)

Whole-codebase audit (not a diff) of ShuTaPla (~8,600 LOC, 62 Swift files), run at
extra-high effort across nine finder angles plus a gap sweep, judged against the
iOS skills (`swiftui-expert-skill`, `swift-concurrency`, `swift-testing-expert`,
`mobile-ios-design`) and the conventions in `CLAUDE.md`. Findings are **uncapped** —
everything surfaced is listed, ranked by category and severity. Each item carries a
**confidence** (how sure the mechanism is real) so you can triage.

Project facts that frame the judgements: Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, macOS 26.4. Default isolation is
MainActor; a plain `nonisolated async` runs on the **caller's** actor, so CPU-bound
work must be `@concurrent` to leave main.

Items marked **[verified]** were confirmed by reading the code directly during this
review; others carry the finder's confidence and a stated trigger.

**Scope.** Per `doc/tasks/index.md`, Tasks 1–14.2 are complete and Tasks 15–19 are not
started. This review covers **completed code only**; features that belong to unstarted tasks
(audio overlay, settings/persistence/lifecycle, cloud, HDR, accessibility) are out of scope
and not listed as defects.

**Status.** A ✅ on a heading means that finding is fixed (on `code-review-fixes`); an
unmarked heading is still open. Done so far: A1, A3, A7, A8, A11, A16, B1, D2, G1–G5, I1–I7.

## Severity summary

| # | Area | High | Medium | Low |
|---|------|------|--------|-----|
| A | Correctness & resource | 3 | 8 | 11 |
| B | Concurrency | 1 | 3 | 1 |
| C | SwiftData lifecycle | 0 | 0 | 1 |
| D | CLAUDE.md rule adherence | 1 | 2 | 2 |
| E | SwiftUI correctness (identity/state) | 0 | 2 | 5 |
| F | HIG / interaction | 0 | 0 | 2 |
| G | Code reuse / duplication | 4 | 2 | 2 |
| H | Simplification / efficiency / constants | 0 | 3 | 8 |
| I | Test suite | 1 | 2 | 4 |

---

## A. Correctness & resource

### ✅ A1 — mpv command/setter methods are not gated on `isTerminated` (use-after-free after shutdown) **[verified] · High**
`MPVClient.swift:242–301, 372–384`. The reads (`volume` getter `:276`, `isLooping`
getter `:289`, `drainEvents` `:307`) all `guard !isTerminated`, but every **write** —
`loadFile`, `play`/`pause`, `stop`, `seek(to:)`, `seek(by:)`, the `volume`/`isLooping`
setters, and `setProperty(flag:)`/`setProperty(double:)` — does `queue.async { mpv_*(self.handle,…) }`
with no guard. The serial queue runs FIFO, so any command enqueued **after** `shutdown()`'s
block (which sets `isTerminated` and calls `mpv_terminate_destroy`) executes `mpv_command`/
`mpv_set_property` on a freed handle → use-after-free. The line `:144` comment "further
commands become no-ops at the C layer" is false. **Fix:** add `guard !self.isTerminated`
inside each command/setter `queue.async`, mirroring the reads.

### ✅ A3 — Renaming/removing a tag across a playlist doesn't update the active filter → filtered list silently empties **[verified] · High**
`AppState.swift:914–927` (`renameTagAcrossPlaylist`, `removeTagAcrossPlaylist`, `removeTag`)
funnel through `editTags` (`:932–949`), which calls `rebuildTagFrequency` + `recomputeIfSelected`
but never touches `playlist.filterState.selectedTags` or `savedSearches`. Filtering by
`cat`, then renaming `cat`→`feline`, leaves `selectedTags == ["cat"]`; after recompute the
file list / `playbackSequence` go empty and the player drops to a "no files" placeholder.
Saved searches referencing the old tag become dead. **Fix:** rewrite/remove the affected
tag in `selectedTags` (and saved searches) as part of the edit.

### A4 — Single-file (or single-match) sequence re-loads itself on EOF / each slideshow tick **[verified] · Medium**
`MPVPlaybackEngine.swift:170–173` handles `.endFile(.eof)` with an unconditional
`advanceToNext()`; `Array+Cyclic.swift:17` `cyclicSuccessor` on a 1-element array returns
`self[(0+1)%1] = self[0]` — the same file. So a single non-looping video at natural EOF
**full-reloads and re-decodes itself forever** (vs mpv's internal `loop-file`). The image
analogue is `ImagePlaybackEngine.swift:146`: the slideshow timer calls `advanceToNext()`
each tick, re-loading the lone image and resetting `transform` to `.identity` — discarding
any pan/zoom the user set, with a flicker. **Fix:** when the sequence has one element (or
the successor equals the current file), hold the last frame / skip the reload.

### A5 — Natural-EOF `advanceToNext()` touches SwiftData models off the event task after teardown (trap class 2) **[verified] · Medium**
`MPVPlaybackEngine.swift:173`. The `eventTask` is cancelled in `shutdown()`, but an
already-delivered `.endFile(.eof)` being handled walks `playlist.playbackSequence` and
mutates `currentFileID`; if the model context/container is gone it dereferences a freed
model. This is the documented hang risk (CLAUDE.md trap class 2) reachable in the test
host and during real teardown.

### A6 — `AudioStripper.remux` leaves a truncated output file on mid-stream failure · Medium
`AudioStripper.swift:41`. After `avio_open` succeeds, a failure in `write_header`/
`write_frame`/`write_trailer` returns `false` but never deletes the partial output. The
caller sees the error, but a corrupt, unplayable file is left at the destination path.
**Fix:** `try? FileManager.removeItem(at: output)` on every failure path.

### ✅ A7 — Corrupt/0-byte cached thumbnail is treated as a valid hit → cell stuck on placeholder · Medium
`ThumbnailService.swift:178`. `produceData` reads the disk-cache `.heic` with `try?`; a
0-byte or truncated file (interrupted prior write) reads successfully and is returned as
valid data. `produceImage`'s `NSBitmapImageRep(data:)` then returns `nil`, so the cell
shows a placeholder **permanently** — the bad key still "hits" so it's never regenerated.
**Fix:** validate decode (or non-empty length) before treating the cached bytes as a hit;
delete and regenerate on decode failure.

### ✅ A8 — `confirmPlayerDelete` discards the delete error → failed trash silently advances the player · Medium
`AppState.swift:872`: `_ = await deleteFiles([file])`. If the trash fails (permissions/
locked), the model is not deleted but `reconcileVisualSelection` runs and the user gets no
feedback. Every other delete path surfaces the message. **Fix:** present the returned
message (the player has an alert channel — see D2).

### A9 — `handleClick` reads global `NSEvent.modifierFlags` instead of the tap event's modifiers · Medium
`FileListView.swift:121` and `FileGalleryView.swift:144`. `onTapGesture` fires on mouse-up;
`NSEvent.modifierFlags` reflects keyboard state at handler-run time, not click time. The
click-count is read from `NSApp.currentEvent` but the modifiers from the global flags —
inconsistent. Releasing shift/cmd a few ms before mouse-up degrades a shift/cmd-click to a
plain select, collapsing the multi-selection. **Fix:** read both from the same originating
event (`NSApp.currentEvent?.modifierFlags`).

### A10 — `FileGalleryView.columnCount(for:)` ignores the `.adaptive` maximum → keyboard nav stride mismatch · Medium
`FileGalleryView.swift:86`. The grid uses `GridItem(.adaptive(minimum:150, maximum:220))`;
`columnCount` models only `minimum + spacing`. At wide widths `LazyVGrid` may render fewer
columns (capped by the 220 max) than `columnCount` returns, so 2-D arrow navigation (which
uses `appState.fileGridColumns`) steps by the wrong stride and selection jumps to an
unexpected cell. **Fix:** measure the actual column count from rendered cell frames rather
than recomputing it.

### ✅ A11 — `TagParser.parseTags` splits on a single ASCII space while the emptiness check uses `.whitespaces` · Medium
`TagParser.swift:51`. `split(separator: " ")` treats a tab/NBSP-separated bracket as one
token, which fails `isValidTag`, so `clip [beach\tsunset].mp4` is classified `.invalid`
even though the earlier `.whitespaces` check considered the tab whitespace. The two paths
disagree on what "whitespace" means. **Fix:** split on `CharacterSet.whitespaces` (or
`\u{0020}\t\u{00A0}`) consistently.

### A12 — `AppStateModel.fetchOrCreate` swallows the fetch error → can create a duplicate singleton · Medium
`AppStateModel.swift:33`. `try? context.fetch(...)` maps any throw to `[]`, so a transient
failure inserts a brand-new singleton even though one exists on disk. The next launch's
`dropFirst()` deletes one duplicate — losing whichever instance held the active-playlist
IDs / window frame. **Fix:** don't swallow; on fetch failure, abort rather than insert a
second singleton.

### A13 — `FileSystemService.relativePath` uses raw-string `hasPrefix` → symlink/normalization collapses distinct files · Low
`FileSystemService.swift:222`. A symlinked root, or an enumerator path with different
Unicode normalization than `root.standardizedFileURL.path`, fails `hasPrefix(rootPath)` and
falls back to `lastPathComponent`. Two `a.mp4` files in different subfolders then collide on
`relativePath`, so one is dropped / mis-identified on the update delta. **Fix:** compute the
relative path via `URL` path-component arithmetic on standardized URLs.

### A14 — `apply()` skips `cloudStatus` refresh on an empty add/remove delta · Medium-low
`AppState.swift:446`. When a rescan yields no add/remove delta, `apply()` early-returns, so
a file whose iCloud availability changed (local→inCloud) keeps its stale `PlaylistFile.cloudStatus`
and the row badge is wrong. **Fix:** reconcile cloud status independently of the add/remove
delta.

### A15 — Tag-rename collision check misses tags carried only by skipped files · Low
`AppState.swift:916`. The collision check reads `playlist.tagFrequency` (built from
non-skipped files only). A target tag carried solely by an invalid/skipped file isn't
detected, so the rename proceeds and merges onto it on disk. **Fix:** check against all
files' tags, not just `tagFrequency`.

### ✅ A16 — `load()` doesn't reset looping on explicit next/previous · Low
`MPVPlaybackEngine.swift:83` / `:143`. `loop-file=inf` and the engine `isLooping` flag
persist across `loadFile`, so toggling loop on file A then pressing next leaves B looping
forever (and the indicator lit), despite the property doc describing it as "whether the
**current** file loops." **Fix:** clear looping in `load()` (or on advance).

### A17 — `reconcileVisualSelection` leaves a stale current file when the sequence empties · Low
`PlaybackCoordinator.swift:311`. When a filter empties `playbackSequence`, the engine stays
loaded with the removed file and `currentFileID`/`visualCurrentFile` still point at it; the
next advance/seek acts on a file no longer in the playlist. Task 14.1 added the "filter
excludes current file → play next / show no-files placeholder" behavior, so the common path is
covered; this is the residual edge where the sequence goes fully empty. **Fix:** clear the
engine/visual state when the sequence becomes empty. *(Confirm against the Task 14.1
implementation before acting — may already be handled.)*

### A18 — `PlaybackCoordinator.shutdown()` doesn't reset channel bookkeeping · Low
`PlaybackCoordinator.swift:80`. `shutdown()` tears down engines and releases scoped access
but leaves `isSuppressed`/`visualHaltedForOverlay`/`visualPlaylist`/`audioPlaylist` set, so
a reused coordinator (e.g. window reopen on the same instance) reports stale active channels.
**Fix:** reset the channel flags in `shutdown()`.

### A19 — `MPVThumbnailer` timeout path may read a half-written PNG · Low
`MPVThumbnailer.swift:146`. On the 15s deadline path, `downscaledFrame` runs against an
output dir that may hold a truncated/absent PNG (no guarantee mpv finished writing), so a
non-nil duration can accompany a nil/corrupt frame. **Fix:** treat the timeout as a failure
for the frame even when duration was captured at `FILE_LOADED`.

### A20 — AV vs mpv thumbnail frames sampled at different positions · Low
`ThumbnailService.swift:328`. `avAssetFrame` hard-codes a 1s seek while the mpv path picks a
representative (≈10%-in) frame, so the same content yields visibly different thumbnails
across codecs; a <1s clip relies on `.positiveInfinity` tolerance to clamp. **Fix:** sample
the same relative position in both paths.

### A21 — `ThumbnailService.memoryKey` keyed on `folderBookmark.hashValue` (not collision-free) · Low
`ThumbnailService.swift:119`. `Hashable.hashValue` is per-process seeded and can collide;
two playlists whose bookmarks collide, with files sharing `relativePath`+`maxPixelSize`,
get the same in-memory key → one paints the other's thumbnail. **Fix:** key on a digest of
the bookmark bytes (or a stable playlist id).

### A22 — `FileSystemService.dominantType` uses first-match over a dictionary · Low (latent)
`FileSystemService.swift:249`. `Dictionary.first { … >= threshold }` is deterministic only
because the 0.8 threshold lets at most one type qualify; if the constant were ever lowered
to ≤0.5 the winner becomes dependent on dictionary iteration order. **Fix:** select `max(by:
count)` for robustness.

---

## B. Concurrency

### ✅ B1 — `DurationService.extract`/`avDuration` are not `@concurrent` → uncached duration extraction hitches the UI **High**
`DurationService.swift:42`. `nonisolated async` under MainActor-default isolation runs on the
caller's actor; `duration(for:)` awaits `AVURLAsset.load(.duration)` plus the libmpv fallback
**on the main actor** for each uncached file, freezing the UI while the file list/gallery
populates. `ThumbnailService.produceImage` and the image engine satisfy the off-main contract
with `@concurrent`; this one doesn't. **Fix:** mark the extraction helpers `@concurrent`.

### B2 — `renderThumbnail`/`imageThumbnail` offer no isolation guarantee · Medium
`ThumbnailService.swift:226`. The public path is safe because `produceImage` is `@concurrent`,
but `renderThumbnail`/`imageThumbnail` (the latter synchronous) are `nonisolated` only —
documented as "exercised directly by tests" and "shared with MPVThumbnailer." Any caller
already on `@MainActor` that calls them directly runs the `CGImageSource` decode on main.
**Fix:** mark the CPU-bound helpers `@concurrent` so the guarantee is structural, not
incidental to one entry point.

### B3 — `MPVThumbnailer.frame()/duration()` ignore cancellation · Medium
`MPVThumbnailer.swift:39`. `withCheckedContinuation` with no `withTaskCancellationHandler`;
a cancelled gallery cell still blocks the single serial pool to the 15s deadline, starving the
cells that are now on-screen. **Fix:** check `Task.isCancelled` in the extract loop / wire a
cancellation handler.

### B4 — `confirm*` actions launch un-retained, un-cancellable fire-and-forget Tasks touching models · Medium
`AppState.swift:763` and the sibling `confirmManagerDelete`/`confirmAudioStrip`/
`confirmTagRemoval`/`confirmPlayerDelete`. Each `Task { … }` mutates SwiftData after the
method returns and is neither retained nor cancelled when the referenced playlist/file goes
away (CLAUDE.md trap class 2; also a real production hazard on rapid delete-then-switch).
**Fix:** retain and cancel like `updateTask`, or `await` them.

### B5 — `select()` respawns a full folder re-scan on every (re-)select with no debounce · Low
`AppState.swift:350`. Re-clicking the already-selected sidebar row (the documented re-center
gesture) cancels and respawns a full scan Task each click. **Fix:** skip the rescan when the
selection is unchanged, or debounce.

---

## C. SwiftData lifecycle

### C4 — `apply()` derives `nextOrder` from `playlist.files.map(\.sortOrder).max()` right after detaching deletions · Low
`AppState.swift:465`. Relies on the inverse relationship array updating synchronously after
`file.playlist = nil`; if a to-be-removed file still contributes the max, new files get a
colliding `sortOrder`, leaving duplicate orders that break stable playback ordering. **Fix:**
compute `nextOrder` from the surviving set explicitly.

---

## D. CLAUDE.md rule adherence

### D1 — 19 source comments cross-reference "Task N" — writing-rule smell (split by kind) **[verified] · Low**
`OverlayManager.swift:32,35,136`, `AppState.swift:176,702`, `HotkeyRouter.swift:15,16,104`,
`MPVPlaybackEngine.swift:14`, `PlaybackSource.swift:10`, `SettingsView.swift:6`,
`FileRowView.swift:106`, `PlayerView.swift:7–10,178`, `FullscreenView.swift:8`,
`PlaylistSidebar.swift:202`. These are **source-code** comments (not `index.md`, which is
exempt). Two kinds, with different weight:
- **References to *completed* tasks** — e.g. "Keyboard input is owned app-wide by HotkeyRouter
  (Task 12)", "the Task 11 coordinator", "Editing lives in the tag panel (Task 7)". These
  narrate the build order of code that is already in place — a genuine writing-rule smell (a
  reader can tell it "was added in Task N"). **Fix:** drop the parenthetical task number;
  describe the present structure.
- **References to *not-yet-built* features** — e.g. "arrives in Task 15", "Task 16 fills in",
  "Animated, polished transitions are Task 18". These honestly mark absent functionality; the
  only nit is the bare tracker number. Acceptable to leave until those tasks land, then remove.

Low severity overall — cosmetic, no behavioral impact.

### ✅ D2 — Modal confirmations/errors not registered in `HotkeyRouter.hasBlockingConfirmation` → bare keys leak behind them · High
- `PlayerView.swift:96` — the "Couldn't remove audio" alert (`appState.audioStripError`).
- `FilesTagsOverlayView.swift:45–48` — the rename-error alert (view-local `@State errorMessage`,
  with no AppState flag to register).
- `PlaylistSidebar.swift:98–104` — the delete / media-type `confirmationDialog`s (view-local
  `@State`), whose buttons also lack `.defaultAction`/`.cancelAction`.

While any of these is open, the app-wide `NSEvent` monitor still routes `[esc]`/`[enter]`/
arrows/letters to playback or the file list behind the dialog, and the dialog's own shortcuts
never fire. CLAUDE.md requires the modal's AppState flag to be registered (passing
`[enter]`/`[esc]` through, swallowing the rest). **Fix:** lift these error states onto
`AppState` and register them; give the confirmationDialog buttons keyboard roles.

### D3 — Garbled comment in `MPVThumbnailer` · Medium
`MPVThumbnailer.swift:144`. "The file is its duration comes along for free" is a broken,
merged sentence — fails the writing rule's clarity bar and obscures why duration is captured
at `FILE_LOADED`. **Fix:** rewrite the sentence.

### D4 — Files & Tags background single-tap competes with per-row double-tap · Medium-low
`FilesTagsOverlayView.swift:45`. A container `.onTapGesture` (resign first responder) coexists
with each row's `.onTapGesture(count: 2)`; a double-click to play can be partly consumed by
the background tap, reintroducing the disambiguation lag the tap-gesture rule warns against
(here across two views). **Fix:** branch on `clickCount` within a single gesture, or scope the
background tap so it can't intercept row clicks.

---

## E. SwiftUI correctness (identity / state)

### E1 — Tag-chip `ForEach` uses enumeration offset as identity · Medium
`TagTokenField.swift:90`. Removing a middle chip shifts every later offset, so SwiftUI rebinds
chip views to different tags; the `selectedChip` highlight, an open per-chip context menu, and
the remove transition target the wrong pill. Tags are unique per field. **Fix:** `id: \.element`
(the tag string).

### E2 — Order-/name-coupled identities in saved-search and tag rows · Low
`FilterBar.swift:101` (`id: \.self` on `SavedSearch`, whose `Hashable` is over the ordered tag
array) and `PlaylistTagsView.swift:78` (`id: \.name`). In-flight reorders/renames can momentarily
collide identities and animate the wrong row. **Fix:** give these a stable id field.

### E3 — `FileRowView` ignores persisted `file.duration` and always re-fetches on appear · Low
`FileRowView.swift:51`. The duration column flashes empty on every list scroll-in even when the
value is already on the model (the gallery badge reads it synchronously). **Fix:** read
`file.duration` first, await only on a miss.

### E4 — `GalleryCell` assigns the generated image without a post-await cancellation check · Low
`FileGalleryView.swift:215`. On fast scroll/recycle the awaited generation can assign file A's
image into a cell now showing file B until the new task lands — a brief wrong-thumbnail flash.
**Fix:** `guard !Task.isCancelled` before assigning.

### E5 — Playlist inline-rename field lacks select-all and a lost-focus commit path · Low
`PlaylistSidebar.swift:165`. No select-all on focus (unlike `RenameFileField`); clicking away
without submit never fires `onSubmit`/exit, leaving `renaming` set and the draft silently
abandoned. **Fix:** select-all on focus and commit/cancel on focus loss.

### E6 — Image pinch zoom is unclamped mid-gesture and anchored at center · Medium-low
`ImagePlayerView.swift:44–46`. The live preview scale (`transform.scale * magnifyBy`) is
unclamped, so pinching past the 0.1 floor scales toward zero then snaps back on release; and
`scaleEffect` has no anchor, so zoom pivots about the view center rather than the pinch point —
disorienting for a pan/zoom viewer. **Fix:** clamp the live scale and anchor at the gesture
location.

---

## F. HIG / interaction

### F3 — `doublePressInterval` 0.09s makes the documented double-arrow chip jump nearly unreachable · Low
`TagTokenField.swift:358`. 90 ms is shorter than a deliberate double-press, so two left presses
usually register as two single steps. **Fix:** raise toward the system double-click interval.

### F4 — Chip remove (x) target is small and overlaps the chip-select tap · Low
`TagTokenField.swift:152`. A near-miss on the caption-size `xmark` falls through to the chip's
select gesture. **Fix:** enlarge the hit area / separate the targets.

---

## G. Code reuse / duplication

### ✅ G1 — Security-scoped-access dance duplicated across 5 sites · High
`DurationService.swift:43`, `ThumbnailService.swift:147` & `:180`, `FileSystemService.swift:146`,
`ImagePlaybackEngine.swift:166`. Each open-codes `resolve` + `startAccessingSecurityScopedResource`
+ `defer stop` + `appending(relativePath)` + `fileExists`. A forgotten `defer` in any copy leaks
the grant. **Fix:** one `BookmarkService.withScopedAccess(_:) { url in … }` / `withResolvedFile`
helper that guarantees the balance — matches the project's extract-to-helpers convention.

### ✅ G2 — `FileListView` and `FileGalleryView` duplicate the entire selection/scroll/rename scaffolding · High
`FileListView.swift:22–148` vs `FileGalleryView.swift:22–171`. `anchor`/`renamingID`/`draftName`/
`skipSelectionScroll` state, `handleTap`/`handleClick`/`beginRename`/`commitRename`/`targets(for:)`/
`visibleFiles`, and the three `onChange`/`onAppear` scroll-centering blocks are byte-for-byte
identical. Bug fixes must be mirrored or the two presentations drift (already a risk — see A9).
**Fix:** extract a shared `FileBrowser` model / `ViewModifier` in `Shared/`.

### ✅ G3 — `WelcomeView` and `PlaylistSidebar` duplicate the Mixed-folder add flow verbatim · High
`WelcomeView.swift:90–122` vs `PlaylistSidebar.swift:236–269`. `add(_:)`, `typeChoices(for:)`,
`label(for:in:)`, plus the `pending`/`errorMessage`/`isWorking` state and the type-choice prompt
are duplicated — the code comment even says "shared with WelcomeView's logic." **Fix:** one
`AddPlaylistFlow` view-model/modifier.

### ✅ G4 — `advanceToNext()`/`returnToPrevious()` duplicated across the two engine families · High
`MPVPlaybackEngine.swift:116–138` vs `ImagePlaybackEngine.swift:89–107` — identical
`guard source / fileAfter / url / load / engineDidAdvance` bodies. **Fix:** a default
implementation on a shared protocol over the `PlaybackSource` seam (both already hold a weak
`source` and a `load`).

### ✅ G5 — Enum display logic switched inline in views (already drifted) · High-medium
`MediaType` noun: `WelcomeView.swift:113–122` & `PlaylistSidebar.swift:260–269`. `ServiceFilter`
glyph/label: `FilterBar.swift:131–145` & `PlaylistCenterView.swift:168–170` — the labels already
disagree ("files with invalid tagging" vs "invalid tagging"). **Fix:** `MediaType.displayName`
and `ServiceFilter.systemImage`/`.label` on the enums.

### G6 — `fetch-all-Playlists-then-filter-by-mediaType` repeated · Medium
`AppState.swift:325` (`nextSortOrder`), `:496` (`compactSortOrder`), and `reorder`. Each runs an
unbounded `FetchDescriptor<Playlist>()` and filters by `mediaType`. **Fix:** a
`modelContext.playlists(ofType:)` helper (predicate-scoped + sorted) used by all three.

### G7 — Overlay-panel styling duplicated · Low
`PlaybackControlsBar.swift:28`, `PlaylistsOverlay`, `FilesTagsOverlayView` each apply the same
translucent fill + `.environment(\.colorScheme, .dark)` with near-identical comments. **Fix:** a
shared `.playerOverlayPanel()` modifier.

### G8 — `HoverZone` and `CursorAutoHider` duplicate `NSTrackingArea` setup · Low
`HoverZone.swift:42`. Both rebuild a tracking area (`bounds`, `[.activeAlways, .inVisibleRect]`)
in `updateTrackingAreas`. **Fix:** a shared base `NSView`/helper (event sets differ, so keep that
parameterized).

---

## H. Simplification / efficiency / constants

### H1 — Single serial `utility` queue serializes all thumbnail/strip work behind a 15s deadline · Medium
`MPVThumbnailer.swift:31` (and `AudioStripper`). One stuck/slow decode blocks every subsequent
request; a handful of undecodable files stalls the gallery for minutes. **Fix:** bound
concurrency (a small pool / `TaskGroup` cap) instead of a strict serial queue.

### H2 — Bookmark resolved and scoped-access toggled twice per cache miss · Medium
`ThumbnailService.swift:145`. `cacheKey()` and `produceData()` each resolve the bookmark and
start/stop the scope, dropping the grant between them. On a fresh scroll this doubles the
resolve/scope I/O per cell. **Fix:** resolve once per produce (folds into G1).

### H3 — `scan()` re-stats `.isRegularFileKey` despite prefetching it · Low
`FileSystemService.swift:176`. `resourceValues(forKeys: [.isRegularFileKey])` re-fetches metadata
already prefetched via `includingPropertiesForKeys`, doubling the stat work per file. **Fix:** use
the prefetched value.

### H4 — `writeTags` re-scans brackets already scanned by `parseTags` · Low
`TagParser.swift:159`. Each edit scans the bracket at least twice. **Fix:** thread the existing
`BracketScan` through.

### H5 — `maxPixelSize = 440` magic number coupled to the cache budget but unshared · Medium (constants)
`FileGalleryView.swift:191` hard-codes 440 while `ThumbnailService.swift:39` reasons "a 440px
thumbnail decodes to ~0.6 MB" to size its 128 MB cache budget. Raising the cell size silently
breaks the budget assumption. **Fix:** one `AppConstants` value referenced by both.

### H6 — Selection-highlight opacities have already drifted across 6 sites · Low (constants)
`FileRowView.swift:40` (0.22), `PlaylistsOverlay.swift:74` (0.22), `PlaylistCenterView.swift:188`
(0.22), `PlaylistSidebar.swift:193` (0.18), `FileGalleryView.swift:199` (0.15). **Fix:**
`AppConstants.selectionHighlight` / a `.selectionBackground()` modifier.

### H7 — `FlowLayout` ignores its `Layout` cache and measures subviews twice per pass · Low
`FlowLayout.swift:16`. `sizeThatFits` and `placeSubviews` each call `sizeThatFits` on every
subview, and the chip field re-measures on each keystroke. **Fix:** memoize via the `cache`
parameter.

### H8 — Saved-search edits re-encode the whole embedded JSON array · Low
`AppState.swift:1014`. `promote`/`removeSavedSearch` reassign `playlist.savedSearches` wholesale,
triggering a full JSON re-encode + persist per filter change. **Fix:** mutate in place where
possible.

### H9 — Count-aware singular/plural titles hand-built twice · Low
`PlaylistCenterView.swift:94` (`deleteTitle`) and `:101` (`audioStripTitle`) share the same
`count == 1 ? … : …` shape. **Fix:** a small pluralization helper / `AttributedString` inflection.

### H10 — `PauseOverlay` Unpause `.keyboardShortcut(.space)` is dead · Low
`PauseOverlay.swift:32`. The router intercepts `[space]` before it reaches the button, so the
shortcut never fires — misleading dead code that looks like a fallback. **Fix:** remove it (or
document that routing owns it).

### H11 — Manual get/set Bindings mutate SwiftData directly, bypassing the AppState mutation pattern · Low
`PlaylistCenterView.swift:145` (viewMode) and `FilterBar.swift:60` (filter mode) build manual
Bindings whose read source differs from the setter's write path, so displayed value and written
value can momentarily disagree and the write is untestable in isolation. **Fix:** route through
AppState (or `@Bindable`) consistently.

---

## I. Test suite

### ✅ I1 — `endOfFileAdvancesViaSource` drives a real engine to natural EOF (trap-class-3 risk) · Medium
`PlaybackEngineTests.swift:68`. It loads a real 1s sine into `AudioPlaybackEngine` and waits up
to 12s for natural EOF → `advanceToNext` — exactly the post-teardown advance the rules say to
avoid (the rules mandate **empty** placeholder files so loads fail without reaching `advanceToNext`).
It relies entirely on the `isTerminated` gate holding under timing pressure; a lost race hangs
the whole run. **Fix:** use an empty fixture / a mock source, or assert advance via the
synchronous path.

### ✅ I2 — `slideshowAdvancesAfterInterval` can leave a timer tick scheduled past teardown · Low
`PlaybackEngineTests.swift:182`. The 0.1s slideshow `Task` keeps calling `advanceToNext`; if it
lands after the body returns it matches trap-class-2 (benign here only because the files aren't
context-backed). `stopSlideshow` runs only if the poll returned. **Fix:** `defer` the stop.

### ✅ I3 — Triple `select()` awaits only the last task (trap-class-2 risk) · Low
`AppStateTests.swift:427`. Each `select` launches an un-awaited `updateTask`; the intermediate
ones are left running. A cancelled-but-still-running `apply(delta:)` after teardown traps
intermittently. **Fix:** set state directly or await each.

### ✅ I4 — `ShuTaPlaTests.example` is an empty template test · High (cleanup)
`ShuTaPlaTests.swift:13`. No assertions — can never fail, only noise. **Fix:** delete it.

### ✅ I5 — Coverage gaps for testable core logic · Medium
None of these are covered: `Array+Move` multi-index/downward move (`Array+Move.swift:15`),
`Array+Cyclic` no-match (`→ first/last`) and empty (`→ nil`) branches (`Array+Cyclic.swift:17`),
`moveFileSelection` grid-edge clamp branches (`AppState.swift:813`), `stripAudio` orchestration
(spinner-id balance, on-screen reload/seek/pause restore, sidecar cleanup) (`AppState.swift:583`),
`saveCurrentSearch` 10-item cap + empty-filter no-op (`AppState.swift:991`),
`PlaybackCoordinator.playNow`/`togglePause` (`:281`) and `haltVisualForOverlay`/`resumeVisualForOverlay`
(`:323`), `HotkeyRouter` audio/visual **arrow overlay-control** branches (`:270`), and
`BookmarkService` stale-bookmark / over-release handling. These are pure or seam-injectable —
the cheap, high-value tests the project's own "tests lead the work" rule asks for. **Fix:** add
targeted unit tests (several can be parameterized).

### ✅ I6 — Shuffle-order-sensitive assertions are theoretically flaky · Low
`FileSystemServiceTests.swift:222` asserts `s1 != input` (a correct shuffle can leave order
unchanged for some seeds), and `AppStateTests.swift:188` asserts an exact skipped-name order over
Fisher-Yates-shuffled input (holds only because one element is skipped). **Fix:** assert the
permutation/determinism invariants (sorted equality, `s1 == s2`) and use sets where order is
irrelevant.

### ✅ I7 — Repetitive routing tests rebuild the fixture inline · Low
`HotkeyRouterTests.swift:122`. Many near-identical player/manager tests rebuild
container+folder+playlist+appState+router by hand. **Fix:** a shared suite `init`/helper or a
parameterized `@Test(arguments:)` over (key, expected effect), per the swift-testing guide.

---

## Notes on what was checked and found clean

- **Tap-gesture rule (count:1 + count:2 stacking):** the file list/gallery rows correctly use a
  single gesture branching on `clickCount`. The only related smell is the Files & Tags background
  tap (D4).
- **`@unchecked Sendable` on `MPVClient`:** the serial-queue invariant and `nonisolated(unsafe)`
  annotations are internally consistent and documented; the only gap is the missing write-side
  `isTerminated` guard (A1), not the Sendable reasoning.
- **`renderLock` scope** around `render`/`reportSwap`/`freeRenderContext` is correct (a free waits
  for an in-progress render; a render after free sees `nil`). The residual risk is only the
  deinit-without-shutdown path (see A1's neighborhood).
- **Change-narration symptom phrases** ("no longer", "previously", "now uses") were grepped
  across the tree — the hits all describe present runtime state or spec behavior, not history.
  The only writing-rule smell is the back-referencing "Task N" comments (D1).
