# Large-playlist performance (select / tag-edit / relaunch lag)

## Symptom (reported)

With a ~1800-file playlist (video **and** image), noticeable lag on:

1. **Selecting a playlist** in the sidebar.
2. **Adding one tag to one file.**
3. **Relaunching** the app with a big playlist selected (small playlists don't lag).

Switching back and forth between two same-scope playlists gets *somewhat* faster on
repeats "but not always" — a warming effect (SQLite page cache / SwiftData row cache /
OS file cache), which points at repeated full-table work rather than a one-time cost.

## Profiling findings (before-index trace)

Trace: `profiling/large_playlist/before-index.trace` (SwiftUI template, 111.7 s wall, one
warm-attach session driving select / tag-edit on the ~1800-file playlist). Analyzed by
re-aggregating the per-sample backtraces (leaf-first, 25–60 frames) restricted to the
main thread inside the 16 hang windows, then bucketed by call path.

### The lag is 16 main-thread microhangs, and every one is a store fetch

- **16 hangs, 4.29 s total, each ~250–326 ms, all 100 % CPU-bound on main.** They cluster
  in two bursts (29–46 s and 57–74 s) — the two big-playlist selections in the session.
- **0 % of the 4.29 s has any ShuTaPla frame on the stack** (20 ms of 4283 ms). The hang
  stacks bottom out at `main()` → run loop → CoreData/SwiftData with no app code between.
  Background threads are near-idle in these windows (388 ms), so the scan actor is *not*
  the competitor — the cost is synchronous work the framework runs on the **main**
  `ModelContext`.
- Whole session, the main thread ran **26.3 s of 111.7 s**. Two costs own it:
  1. **CoreData/SQLite on main: 4.28 s** — and this ≈ the entire hang budget. The hangs
     *are* these fetches; the rest of the session the store is quiet on main.
  2. **SwiftUI graph updates: 13.1 s (50 % of main)** — a separate, diffuse cost spread
     across the whole session (consistent with 1879 hitches / 22.5 s hitch time). Not the
     reported select/tag-edit lag, but the larger steady-state / scroll cost.

### Anatomy of the 4.28 s of main-thread store work

Every hang is `NSManagedObjectContext.performAndWait` (SwiftData wrapping a synchronous
`fetch` / `fetchCount` / `fetchIdentifiers` on the main context). By work type:

| Bucket | Share of hang time |
|--------|--------------------|
| Row materialization (Hasher.init, malloc/free, ARC retain/release, dynamic casts) | **~60 %** |
| SQL **generation + parse** (`NSSQLGenerator`, `generateSQLString`, `sqlite3RunParser`) | **20 %** |
| SQL **execution** (`sqlite3VdbeExec`, `sqlite3PagerSharedLock`) | **10.6 %** |
| Change merge / notify, save/commit, relationship faulting | ~7 % combined |

Two things stand out: SQL **generation/parse is 2× execution** — each fetch builds a fresh
`#Predicate` → fresh SQL string that SQLite re-parses from scratch, i.e. no prepared-statement
reuse. And the majority (~60 %) is just materializing/hashing/allocating result rows. The
leaf syscalls the user noticed (`__fcntl`, `kevent_id`, `mach_vm_purgable_control_trap`) are
the tails of this: `fcntl` is SQLite file locking, `kevent` the dispatch barrier-sync hop
onto the context queue, `purgable_control` the allocator churning result memory.

### Why it fires so often

The file browser and its chrome read the store **on every view-body invalidation**, each
read a full-playlist fetch that is never memoized:

- `AppState.managerFileIDs` → `displaySequence(of:)` → a full **~1800-row `fetchIdentifiers`**
  (`FileCollectionView.body` reads it once per render).
- `Playlist.serviceFilterCounts` → **three** full `fetchCount`s (`PlaylistCenterView`).
- `Playlist.hasPlaybackFiles` → another `fetchCount` (several toolbar/affordance sites).

These are plain computed properties that hit the store each call; the only Observation gate
is `_ = appState.sequenceVersion`. Selecting a playlist and **adding one tag both call
`persistAndRefresh` → `sequenceVersion &+= 1`**, which invalidates every consumer at once
and re-runs the whole set of full-table fetches. That is the select-lag and the
add-one-tag lag, same mechanism.

### What the index (already committed) does and does not fix

The `#Index` on the playback sequence (commit *Add indexes for playlist sequence*, added
**after** this trace) targets only the **execution** bucket (~10 %) — the `VdbeExec` /
`SharedLock` scan-and-sort. It does **not** touch SQL parse (20 %) or row materialization
(~60 %), which are the larger share. So the index alone is not expected to remove the hang;
a re-profile after it should quantify the residual. The frequency and size of the fetches are
the dominant levers.

## Plan

### Step 1 — Memoize the derived sequence-ID accessors in `AppState` (chosen, in progress)

The biggest lever: cut fetch *frequency*. The three full-fetch accessors —
`managerFileIDs` (`displaySequence`), `audioChannelFileIDs` (`playbackSequence`), and
`visualChannelFileIDs` (`displaySequence`) — re-run a whole-playlist `fetchIdentifiers` on
**every** access, i.e. every view-body invalidation. Memoize each behind an
`@ObservationIgnored` slot keyed on `(sequenceVersion, playlist identity)`, so the fetch runs
once per real change and repeated reads within a render pass reuse the result.

Safety: `sequenceVersion` is already the *sole* Observation gate these accessors rely on
(`_ = sequenceVersion`), documented as bumped after every persisted mutation that changes a
sequence's membership/order; a playlist switch changes the accessor's source playlist. So the
memo is no staler than today's gate — every production mutation path (`toggleFilterTag`,
`setTagFilter`, `manage`, tag rename/remove, scan apply) bumps the version or changes the
playlist, which the existing multi-read tests already exercise. Each accessor reads a single
playlist per pass (managed / audio channel / live visual), so a one-slot-per-accessor cache
never thrashes.

Scope held tight on purpose: `currentAudioFile`/`currentVisualFile` (single-row resolves, not
the 60 % materialization cost) stay as-is, and the `fetchCount`-based `serviceFilterCounts` /
`hasPlaybackFiles` are **deferred to after the re-profile** — they're `Playlist` forwarders
read for possibly-multiple playlists per pass, so they need a keyed cache, not a single slot;
decide once the re-profile shows whether they still matter.

### Step 2 — Re-profile (done)

Trace: `profiling/large_playlist/after-step1.trace` (SwiftUI template, 239 s warm-attach,
same select / tag-edit on the ~1800-file playlist plus fullscreen play↔back switching).
Analyzed the same way (main-thread samples inside the hang windows, bucketed by
nearest-to-leaf app frame; attribution via `atos` against `ShuTaPla.debug.dylib`).

**The hang budget roughly halved: 16 hangs / 4.29 s → 8 hangs / 2.04 s (−52 %)** — despite a
~2× longer session with more interactions, so per-interaction the win is larger. Remaining
hangs are 100 % CPU-bound on main with the same store-fetch leaf signature (`kevent_id`
barrier-sync, `__fcntl` SQLite lock, `purgable_control`/`_xzm_free`/`swift_release` row
materialization).

But the **composition changed completely**. Before, ~0 % of hang time had any app frame on
the stack (pure framework). Now **51 % of hang-window main samples carry an app frame**, and
one site dominates:

| Nearest-to-leaf app frame → caller | Samples (of ~16 k in-window) | What it is |
|---|---|---|
| `PlaylistFile.id.getter` ← `TagSidebar.selectedFiles(in:)` | **5135 (~32 %)** | walks the whole `playlist.files` relationship, reads `.id` on all ~1800 to intersect the tiny selection |
| `ShuTaPlaApp.$main()` (no deeper app frame) | 2095 | irreducible SQL gen/parse/exec of the surviving fetches |
| `modelContext.save()` (AppState.init persist closure) | 150 | the tag-add commit |
| `ManagerSplitViewController.attachToolbarIfNeeded` ← `viewDidAppear` | 103 | AppKit toolbar attach |
| `playbackFiles(of:)` closure | 36 | a playback-sequence fetch (first-fill of the audio channel memo) |
| `Int.formattedFileSize` / `GalleryCell.thumbnail` / `FileCollectionView.body` closures | ~70 combined | gallery-cell metadata rendering |
| `ModelContext.count` ← `hasPlaybackFiles(in:)` | 17 | the deferred count fetch |

Two conclusions:

1. **Step 1 worked.** The memoized sequence accessors (`displaySequence` /
   `identifiers(matching:)`) are now a rounding error (~15 samples). The 60 %-materialization
   sequence-fetch hang is gone.
2. **The new dominant residual is `TagSidebar.selectedFiles(in:)`** — and the deferred count
   fetches (`serviceFilterCounts` / `hasPlaybackFiles`) are now *negligible* (17 samples), so
   the "Later" count-cache work is no longer warranted.

### Step 3 — Stop faulting the whole `playlist.files` relationship in view bodies (done)

A code sweep for `playlist.files` (mutation/scan paths excluded — those legitimately
materialize) found **three view-body sites** that fault the entire to-many relationship on
render. `.count` and `.filter`/`.sorted` on a SwiftData to-many are not lazy: each faults all
~1800 rows into memory. Two sub-changes, one theme:

**3a — `TagSidebar.selectedFiles(in:)` → `AppState.selectedManagerFiles()`** (trace-proven, 32 %).
A slow duplicate of `AppState.selectedManagerFiles()` (AppState.swift:298): both yield the
manager selection's files in display order, unrestricted by the effective filter; TagSidebar
always operates on `appState.managedPlaylist` (`TagSidebar.body` line 20), exactly
`selectedManagerFiles()`'s source. The difference is only *how*:

- `TagSidebar`: `playlist.files.filter { managerSelection.contains($0.id) }.sorted { … }` —
  materializes all ~1800 rows and reads `.id` on each (the 5135-sample burst).
- `selectedManagerFiles()`: a scoped `FetchDescriptor` with
  `#Predicate { playlist == pid && ids.contains($0.id) }`, `includePendingChanges = false` —
  pushes the filter into SQLite and materializes only the small selection.

Replace the body of `TagSidebar.selectedFiles(in:)` with `appState.selectedManagerFiles()`
and drop the now-redundant local helper / `playlist` argument.

**3b — the two sidebar row counts → a `fetchCount` forwarder** (latent, not trace-proven).
`PlaylistSidebar.swift:152` and `LibrarySurface.swift:121` both render
`Text("\(playlist.files.count)")` once per playlist row — a full relationship fault per row
just to print a number, so a big playlist slows every sidebar re-render (and cold start). Add
a public `ModelContext.fileCount(in:)` over the existing private `count(_:)` primitive (real
SQL `fetchCount`, zero materialization — the same seam `serviceFilterCounts` uses) and point
both rows at it.

Test-first: (1) assert the TagEditor input equals `selectedManagerFiles()` for a multi-file
selection before the 3a swap; (2) assert `fileCount(in:)` equals `playlist.files.count` for a
seeded playlist before wiring 3b.

**Done.** 3a: `TagSidebar.selectedFiles(in:)` removed; the editor now takes
`appState.selectedManagerFiles()`. 3b: added `ModelContext.fileCount(in:)` (a `fetchCount`
forwarder) and its `Playlist.fileCount` ergonomic wrapper; `PlaylistSidebar` and
`LibrarySurface` row badges read it instead of `playlist.files.count`. Tests:
`selectedManagerFilesMatchesFilteredRelationshipInDisplayOrder` (AppStateTests) pins 3a's
contract; `fileCountMatchesRelationshipCount` + the `playlistForwardersMatchTheContextMethods`
addition (SequenceStoreTests) pin 3b — all run green on the current code before the swaps and
after. Build clean, no navigator issues.

### Step 4 — Scope-switch lag: collapse the gallery/list view-type swap (done, pending user feel-test)

**Symptom (reported, then confirmed by the user).** After Steps 1 + 3, the one remaining lag
is switching the Manager *scope* — surprisingly, slower than quit-and-relaunch. The user
confirmed the cause behaviourally: switching to a scope whose playlist uses the **same**
presentation (gallery→gallery / list→list) has **no** lag; only a cross-presentation switch
(gallery↔list) lags.

**Cause.** `FileCollectionView<Cell>` is generic over its cell type. `PlaylistCenterView.center`
picks the presentation with an `if/else`:

- gallery → `FileGalleryView` → `FileCollectionView<GalleryCell>`
- list → `FileListView` → `FileCollectionView<FileRowView>`

These are two *distinct concrete types*, so a gallery↔list switch changes the subtree's type
identity and SwiftUI tears down and rebuilds the **entire shared scaffold** — the
`ScrollViewReader`, `ScrollView`, all four `@State` fields (anchor / renamingID / draftName /
skipSelectionScroll), and every `onChange`/`onAppear`/`onPreferenceChange` + coordinate space —
even though only the inner container and cell actually differ. A same-scope-type switch keeps
the type and merely re-points `playlist`, so the scaffold survives — hence no lag. Relaunch
builds the scaffold exactly once with no diff, so it too is cheaper than the cross-type swap.

**Fix.** Make `FileCollectionView` a single **non-generic** type that builds the right cell from
its existing `layout` parameter, and delete both wrapper views:

- Drop the `<Cell>` generic and the `cell:` closure. The `body`'s `switch layout` already forks
  `LazyVStack`/`LazyVGrid`; each branch builds its concrete cell (`FileRowView` / `GalleryCell`)
  through a small generic *helper function* `item(_:cell:)` that applies the shared
  `.id`/`.onTapGesture`/`.contextMenu`. (A generic *function* doesn't fragment the enclosing
  view's type — only a generic view *type* does.)
- Move `GalleryCell` (currently private in `FileGalleryView.swift`) into its own
  `GalleryCell.swift`, matching `FileRowView` (which already lives in its own file).
- Delete `FileGalleryView.swift` and `FileListView.swift`; `PlaylistCenterView.center` calls one
  `FileCollectionView(playlist:, layout: … .gallery : .list, …)`.

Now the center is one type across every scope switch: the scaffold and its `@State` persist, and
only the inner `LazyVGrid`↔`LazyVStack` swaps — rendering a single screenful, the operation
already shown to be fast. Net effect is also a dedup: two wrapper structs and a generic
parameter removed.

**Testing / verification.** The extracted pure logic stays covered as-is — `FileCollectionLayoutTests`
(column count) and `FileSelectionTests` (`actionTargets`) are unaffected by the refactor. The
identity fix itself is a SwiftUI view-graph property (not unit-testable at the body level); it's
verified against the user's live reproduction (cross-layout scope switch no longer lags, both
presentations still render/select/rename correctly) plus a clean build and empty navigator. One
benign behaviour change to note: rename/anchor `@State` now persists across a layout switch
instead of resetting.

**Done (code).** `FileCollectionView` de-generic'd (the `<Cell>` param and `cell:` closure
gone; `item(_:cell:)` is now a generic *function* each layout branch calls with its concrete
cell). `GalleryCell` moved to its own `GalleryCell.swift`; `FileGalleryView.swift` and
`FileListView.swift` deleted. `PlaylistCenterView` calls one `FileCollectionView(…, layout:)`.
Build clean, no navigator issues; the extracted-logic coverage (`FileCollectionLayoutTests`,
`FileSelectionTests`) stays green. **Pending:** user relaunches the new build and confirms the
cross-layout scope switch no longer lags and both presentations still render/select/rename.

### Later (not yet scheduled)

- **The 13.1 s SwiftUI graph cost (50 % of main).** The `swiftui-causes` lane came back empty
  on the host Mac; needs the `AG::Graph` inference pass to find what keeps invalidating the
  browser view. Own track from the select/tag-edit lag.
