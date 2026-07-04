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

### H2 — no SwiftData `#Index`; every store-side sequence read is a full table scan + sort
`PlaylistFile` declares no `#Index`. Every `displaySequence` / `playbackSequence` /
`serviceFilterCounts` / `displayMember` fetch (`ModelContext+Sequence.swift`) filters
`PlaylistFile` on `playlist == pid && …` and sorts by `sortOrder` with no supporting index,
so SQLite scans the **whole** `PlaylistFile` table (all playlists' files, not just this one's
1800) and sorts. These run on every body evaluation and every `sequenceVersion` bump. A
compound index on the playlist relationship + `sortOrder` (and scalar indexes for the triage
columns) turns the scans into index lookups. Best-explains symptoms 1 and 3, and the warming
behavior.

### H4 — automatic full-folder rescan on *every* selection
`manage` → `rescan` re-reads the entire folder from disk (1800 stat calls) and reconciles on
every click, including re-selecting the open playlist. The scan itself is off-main (the
`FileSystemService` actor), but `applyScanResult` then bumps `sequenceVersion` and runs
`coordinator.reconcile`, forcing the store-side lists to re-derive (H2). On relaunch this
fires for the restored selection on top of the initial gallery build. Contributes to
symptoms 1 and 3 and to the "faster on repeat" warming.

### H5 — per-visible-cell metadata write-back
`GalleryCell.task` calls `file.merge(result.metadata)` for each freshly-decoded visible cell,
dirtying the context. Minor next to H1–H4, but worth watching in the trace since it interacts
with `sequenceVersion` churn.

## Settled plan (decided with user)

Ordered so the cheap, high-confidence wins land first; each step is implemented on its own,
test-first, and measured before the next.

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

**Empirically settled (Step 3.1 / 3.3, via `SchemaIndexMigrationTests` + raw `sqlite_master`
inspection).** A SwiftData `#Index` never reaches an already-existing store from an index-only
change: fetch indexes are excluded from CoreData's entity **version hash**, so the source/destination
hashes match, CoreData deems the store already compatible, **no migration runs, and the index is
never created** (Apple WWDC 2017 Session 210). CoreData's own remedy is `versionHashModifier` (a
zero-storage metadata string that flips the hash), but **SwiftData does not surface it** — the real,
narrow gap. Proven truth table:

- Fresh store → index present (built from scratch).
- Index-only change, even a bumped `versionIdentifier` → **no** index (hash unchanged → migration skipped).
- A migration triggered by *any* hash change reconciles **every** entity's declared indexes — the
  triggering change may live on a **separate table**, even a standalone entity with no relationships.
- Dropping a column is a supported lightweight change (row + index preserved) — column deletion is not a gap.

**Decision (with user): the marker-entity approach — one release, robust, reusable.** Ship the
`#Index` together with a new **permanent, empty `@Model SchemaMarker`** entity. Every existing store
lacks that entity, so its hash always mismatches the new model → the lightweight migration always
runs → the index is applied, **independent of which prior app versions the user installed.** Rejected
alternatives and why:
- *Index-only, no bump* — reaches no existing store (only new installs).
- *Permanent throwaway column on `PlaylistFile`* — pollutes a real table forever.
- *Two releases (add nonce, later drop it)* — fragile: a user who jumps the pre-nonce version
  straight to the post-nonce one hits the hash-match short-circuit and never reindexes.
The marker is kept forever (removing it re-opens the short-circuit) and is the reusable lever for the
next forgotten index — perturb its hash (add/rename a property) in that release.

**Implementation — done.** All five steps below landed: `SchemaV5` frozen to pinned pre-index
models; `SchemaV6` = live types + the new empty `@Model SchemaMarker`; `PlaylistFile`'s `#Index` set
to the settled compound set; `AppMigrationPlan` = `[SchemaV5, SchemaV6]` with a `.lightweight`
V5→V6 stage; `ShuTaPlaApp` points at `SchemaV6`. `SchemaIndexMigrationTests` trimmed to the single
`migratingAV5StoreAddsTheSequenceIndex` (a V5 store with rows/tags/skip reopens through the plan into
V6 with rows intact and the `(playlist, …, sortOrder)` index present, SQLite-verified). Build clean,
0 navigator issues, migration test + 39 model/tag/sequence tests green. `doc/versioning.md` corrected
(the `#Index` fetch-index trap + the marker mechanism).

**Original plan (all steps done), test-first:**
1. Freeze `SchemaV5` as pinned pre-index models (pin the Playlist/PlaylistFile/Tag component;
   `AppStateModel`/`GlobalSettings` stay live).
2. Add `SchemaV6` = live types + `SchemaMarker`; add the `@Model SchemaMarker`; set the `#Index`
   on `PlaylistFile` to the settled set (below).
   - **Index set (decided with user).** Every store-side query filters on `playlist` **and**
     `isSkipped` (both equality) before sorting by `sortOrder`, so `isSkipped` is folded *into* the
     compound — not left a residual, which would force a per-row table lookup to read the boolean.
     - `[\.playlist, \.isSkipped, \.sortOrder]` — no-filter / skipped / tag-filter base: a
       contiguous, already-ordered index range, no per-row lookups.
     - `[\.playlist, \.isSkipped, \.taggingStatusCode, \.sortOrder]` — `serviceFilterCounts` become
       index-range counts on the 3-column prefix; the sorted triage display uses all four.
     - `[\.id]` — single-file resolve (`identifier(of:)`, member tests).
     - The naked `[\.taggingStatusCode]` scalar is dropped (never chosen — not leading, low
       selectivity). The tag filter joins the many-to-many **junction table**, which no fetch index
       can cover (`#Index` takes only stored/to-one keypaths); `Tag.normalizedName`'s uniqueness
       index plus the `(playlist, isSkipped)` narrowing are what make it fast — nothing more to add.
3. `AppMigrationPlan` → `[SchemaV5, SchemaV6]`, `stages: [.lightweight(V5→V6)]`; point `ShuTaPlaApp`
   at `SchemaV6`.
4. One migration test: a V5 store with rows/tags/skip reopens through the plan into V6 with the rows
   intact and the `(playlist, sortOrder)` index present (SQLite-verified). Trim the exploratory probe
   scaffolding from `SchemaIndexMigrationTests`.
5. Correct `doc/versioning.md` (its `#Index` line is wrong on both counts — no stage is needed to
   *open*, and a stage does not deliver the index to existing stores) and fold in the mechanism +
   marker pattern.

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

Steps 1 (H1) and 2 (H3) done. **Step 3 (H2) reinstated as scale/hygiene** (not a lag fix —
the trace shows the index's warm ceiling is ~0.26%; it earns its keep on larger stores and the
tag-filtered `SUBQUERY` path). Prep done: schema history collapsed to the single `SchemaV5` baseline
(build clean, 33/33 model+tag tests green), with the mechanics captured in `doc/versioning.md` and
`doc/profiling.md`. **Step 3 mechanism now empirically settled** (truth table above; 6 green
`SchemaIndexMigrationTests`) and the **marker-entity design decided with the user**. **Step 3 is now
implemented** (marker entity + V5→V6 lightweight migration + the settled index set; migration test and
39 model/tag/sequence tests green, build clean, 0 navigator issues). Separately, the *reported lag* lives elsewhere and is the bigger win:
the main-thread **filesystem syscalls + view/allocation churn** the trace indicts (overlaps H5
per-cell metadata and H4 rescan apply).
