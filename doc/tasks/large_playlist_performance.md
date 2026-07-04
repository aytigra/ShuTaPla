# Large-playlist performance (select / tag-edit / relaunch lag)

## Symptom (reported)

With a ~1800-file playlist (video **and** image), noticeable lag on:

1. **Selecting a playlist** in the sidebar.
2. **Adding one tag to one file.**
3. **Relaunching** the app with a big playlist selected (small playlists don't lag).

Switching back and forth between two same-scope playlists gets *somewhat* faster on
repeats "but not always" — a warming effect (SQLite page cache / SwiftData row cache /
OS file cache), which points at repeated full-table work rather than a one-time cost.

## Diagnosis

These are code-analysis hypotheses, ranked by how well they fit the symptoms. They should
be **confirmed with an Instruments trace** (swiftui-expert-skill `record_trace.py`, host-Mac
SwiftUI template) before we change code — one change at a time, each measured.

### H1 — `computeTagFrequency` walks *all* files on the main actor for a single tag edit
`AppState.editTags` (every add/remove of one tag on one file) calls
`modelContext.rebuildTagFrequency(of:)` → `computeTagFrequency(of:)`
(`ModelContext+Reconcile.swift:134`), which iterates **every** `playlist.files` (1800) and
each file's `tags` relationship, faulting them all in on the main actor. Same call sits in
`renameFile` and `deleteFiles`. **This is the tag-edit lag** and it is fully on the main
thread. Best-explains symptom 2.

### H2 — no SwiftData `#Index`; every store-side sequence read is a full table scan + sort
`PlaylistFile` declares no `#Index`. Every `displaySequence` / `playbackSequence` /
`serviceFilterCounts` / `displayMember` fetch (`ModelContext+Sequence.swift`) filters
`PlaylistFile` on `playlist == pid && …` and sorts by `sortOrder` with no supporting index,
so SQLite scans the **whole** `PlaylistFile` table (all playlists' files, not just this one's
1800) and sorts. These run on every body evaluation and every `sequenceVersion` bump. A
compound index on the playlist relationship + `sortOrder` (and scalar indexes for the triage
columns) turns the scans into index lookups. Best-explains symptoms 1 and 3, and the warming
behavior.

### H3 — `managerFileIDs` recomputed (a fresh fetch) several times per render
`FileCollectionView.visibleFileIDs` returns `appState.managerFileIDs`, read from `body` in
the `ForEach`, again in the `.overlay { if visibleFileIDs.isEmpty }`, and again in
`handleClick` — each a full 1800-id fetch (see H2, no index). Nothing memoizes it within a
render pass. Compounds H2 by a constant factor on every interaction.

### H4 — automatic full-folder rescan on *every* selection
`manage` → `rescan` re-reads the entire folder from disk (1800 stat calls) and reconciles on
every click, including re-selecting the open playlist. The scan itself is off-main (the
`FileSystemService` actor), but `applyScanResult` then bumps `sequenceVersion` and runs
`coordinator.reconcile`, forcing the store-side lists to re-derive (H2/H3). On relaunch this
fires for the restored selection on top of the initial gallery build. Contributes to
symptoms 1 and 3 and to the "faster on repeat" warming.

### H5 — per-visible-cell metadata write-back
`GalleryCell.task` calls `file.merge(result.metadata)` for each freshly-decoded visible cell,
dirtying the context. Minor next to H1–H4, but worth watching in the trace since it interacts
with `sequenceVersion` churn.

## Settled plan (decided with user)

Ordered so the cheap, high-confidence wins land first; each step is implemented on its own,
test-first, and measured before the next.

### Step 1 — H1: incremental `tagFrequency` (no full recompute on edit) ✅
Precise per-edit frequency isn't important: the automatic rescan that runs on playlist
switches re-derives it, so an edit only needs to apply its own **delta** to
`playlist.tagFrequency` for the touched (non-skipped) files, not re-walk all 1800. Replace the
`rebuildTagFrequency` calls in the incremental main-actor edit paths (`editTags`, `renameFile`,
`deleteFiles`) with a delta update; the full `computeTagFrequency` stays as the rescan's
authoritative rebuild. Note `tagFrequency` counts only non-skipped files.

**Done.** `PlaylistFile.tagFrequencyNames` gives a file's frequency contribution (its tags'
canonical names, empty when skipped); `ModelContext.applyTagFrequencyDelta(to:before:after:)`
folds one file's `before`→`after` change into the cache (dropping a key at zero). The three edit
paths capture `before`, mutate, then apply the delta; `reconcile` keeps the full `rebuildTagFrequency`.
Covered by `TagFrequencyTests` (a parity test asserting the delta tracks an independent full
recompute across gain/lose/new-tag/zero-drop/skip-toggle/delete), plus the existing edit-path
suites in `AppStateTests`. All green, no navigator issues.

### Step 2 — H3: compute `managerFileIDs` once per render ✅
`FileCollectionView` reads `appState.managerFileIDs` 2–3× per body (ForEach, empty-overlay,
click). Bind it to one local `let` in `body`. Cheap, no schema/behavior change.

**Done.** `body` now snapshots `visibleFileIDs` into one `let ids` inside the `ScrollViewReader`
closure, shared by the active layout's `ForEach` and the empty-state `.overlay` — one
`displaySequence` fetch per render instead of two. Reading it there still registers the
`sequenceVersion` Observation dependency that drives re-renders. `handleClick` keeps its own
fresh read (a separate mouse event, where the list may have moved on). No schema/behavior change;
the returned identifiers are already pinned by `managerFileIDsAreTheOrderedStoreSequenceResolvedByFileFor`
and the `SequenceStoreTests` suite, all green, clean navigator.

### Step 3 — H2: add `#Index` to `PlaylistFile` — **reinstated as scale/hygiene, not a lag fix**
A compound index for the (playlist, `sortOrder`) access path plus scalar indexes for the triage
columns. Decided (with user) to do it: it is the close-the-gap follow-up to the V1→V2 tag
normalization, which built the filter *columns* (`taggingStatusCode`, the `Tag` relationship) but
never the indexes that make filtering them fast. It scales, and it helps the **tag-filtered**
sequence most — a tag filter turns the query into a `SUBQUERY`/join over the `PlaylistFile`↔`Tag`
many-to-many, the worst-scaling path unindexed.

**It is *not* the cure for the reported lag** — the profiling proves that, and the two must not be
conflated. Warm profiling (SwiftUI template, host Mac, single attached instance, 1412-file image
playlist; ~111s: select → switch playlists 4–5× → scroll): 16 main-thread microhangs (4.3s total,
all 100% main-thread CPU-bound) + 1879 scroll hitches. The whole SwiftData/CoreData/SQLite stack is
**772ms = 2.27%** of the 34s of profiled main-thread CPU, and it splits so an index touches only a
sliver: query **execution** (`sqlite3VdbeExec` ≈ **90ms / 0.26%**, all queries) is the only part an
index shrinks; SQL **compilation** (`sqlite3RunParser`/`GetToken`/codegen) and object **hydration**
(`PlaylistFile.init(backingData:)`, backing-data getters, snapshots) are untouched by indexing. The
4.3s of user-visible hangs are **filesystem syscalls on main** (`__getattrlist` 540ms,
`__open`/`__open_nocancel` 432ms, `__fcntl` 150ms), **object/allocation churn**
(`swift_retain`/`swift_release` + refcount slow paths, `_xzm` malloc, bridging, `tryCast`), and
**SwiftUI attribute-graph invalidation** (`AG::Graph::propagate_dirty` 385ms, `UpdateStack::update`
366ms). So on the 1412-row warm path the index's ceiling is ~0.26% — the *reason* to add it is the
larger-store and tag-filtered future, not this trace. Trace + full analysis:
`profiling/large_playlist/before-index.trace` (gitignored). Caveat: the host-Mac SwiftUI lane came
back empty (0 events), so view churn is inferred from `AG::Graph`/refcount symbols, not named views.

**Prep done — schema history collapsed.** V1–V4 pinned schemas, `LegacySchema`, and the historical
`MigrationTests` were removed (no store predates V5); `SchemaV5` is the sole baseline referencing the
live types, `AppMigrationPlan` is `schemas: [SchemaV5], stages: []`. Build clean, 0 navigator issues,
33/33 model+tag tests green. The mechanics of adding the next version are now written up in
`doc/versioning.md`, and how the trace was taken in `doc/profiling.md`.

**Implementation, test-first (each verified before the next):**
1. **Settle whether an index-only change even needs a version.** An index derives no data, so it may
   be non-breaking; but the store hash may still change. Verify empirically: build a store at the
   pre-index `SchemaV5` on disk, add `#Index` to the live `PlaylistFile`, reopen through the existing
   plan (no stage) — opens (index is non-breaking) or `loadIssue` (needs a V5→V6 lightweight stage,
   per `doc/versioning.md`). This is the same crash the versioning doc guards against, so it decides
   Step 3's size.
2. Add the `#Index` (compound on `(playlist, sortOrder)` + scalar triage columns), plus the version
   bump/stage if step 1 requires it, plus its migration test.
3. Confirm SwiftData emits the SQLite index and the planner uses it for the sequence query
   (`EXPLAIN QUERY PLAN` against the store). If the `playlist` relationship keypath can't be indexed
   in a compound, ship the scalar indexes that can.

### Step 4 — H4: cheaper rescan *apply* (keep rescan-on-select)
Rescan-on-selection is the feature and stays. Only the **apply** tail is in scope: if the
trace shows `applyScanResult` (version bump + `coordinator.reconcile` + `refreshFromStore`)
is doing avoidable work on a no-op or unchanged rescan, trim it. `deriveInBackground` already
returns early on `!result.changed`, so verify how often a real change actually applies.

### Step 5 — H5: keep lazy metadata out of the sequence path (invariant)
Lazy per-cell metadata fetch (`file.merge`) must **never** bump `sequenceVersion` or refetch a
sequence in place — today it doesn't (no `persistAndRefresh`), and it must stay that way. There
are no metadata-based filters yet, but when they arrive the sequence must be re-derived only by
**rescan**, never by an in-place lazy fetch (which would thrash the list on scroll). This step is
to assert/lock that invariant (a test), not to change current behavior.

## Status

Steps 1 (H1) and 2 (H3) done — incremental `tagFrequency` and once-per-render `managerFileIDs`,
both tested, green, clean navigator. **Step 3 (H2) reinstated as scale/hygiene** (not a lag fix —
the trace shows the index's warm ceiling is ~0.26%; it earns its keep on larger stores and the
tag-filtered `SUBQUERY` path). Prep done: schema history collapsed to the single `SchemaV5` baseline
(build clean, 33/33 model+tag tests green), with the mechanics captured in `doc/versioning.md` and
`doc/profiling.md`. Next: **implement Step 3 test-first** — first settle whether an index-only change
needs a V5→V6 stage (empirical, per Step 3.1), then add the index (+ stage/test if needed) and
confirm the planner uses it. Separately, the *reported lag* lives elsewhere and is the bigger win:
the main-thread **filesystem syscalls + view/allocation churn** the trace indicts (overlaps H5
per-cell metadata and H4 rescan apply) — profile each candidate before changing code.
