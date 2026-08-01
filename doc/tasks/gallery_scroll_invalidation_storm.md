# Task — Gallery scroll invalidation storm

## Symptom

Gallery scroll is jerky, with a hard CPU spike during scroll and a slowdown that grows the more the gallery
is scrolled. It persists on fully-cached rows (thumbnail + complete metadata), so it is not thumbnail-decode
cost. An Instruments trace (host-Mac SwiftUI template) shows scroll is 100% CPU-bound on the main thread in
SwiftUI AttributeGraph churn — the cost is view **re-rendering**, not decode or SQLite.

The trigger is any ordinary, legitimate save while the gallery/chrome is mounted:

- **Per-cell `PlaylistFile` fills during scroll** — `GalleryCell.task` / `MediaMetadataService.metadata`
  `file.merge` + `trySave`.
- **Playback position every ~5s** — `PlaybackCoordinator.persistTimelinePosition` writes `file.lastPosition`.
  Nothing on screen changes, yet the whole chrome re-renders.

## Mechanism — PROVEN

**Any live `@Query` coarsely refaults *its own entity's* registered instances on *every* store save,
regardless of what actually changed.** SwiftData hands the *same* registered instance to the `@Query` and to
every other view holding it (`let playlist: Playlist`), so the refault fires those instances' per-keypath
observation and re-renders every view that reads any field of them.

The app's two `@Query` sites both vend **every** playlist:

- `PlaylistSidebar` — `@Query(sort: \Playlist.sortOrder) private var allPlaylists`
- `LibrarySurface` — `@Query(sort: \Playlist.sortOrder) private var allPlaylists`

So any `PlaylistFile` fill or `lastPosition` save → store `willChange` → the sidebar's `@Query` re-fetches →
**every `Playlist` instance is refaulted** → the whole chrome/gallery (which reads `Playlist` fields in
`body`) re-renders. That is the storm.

### How it was proven (control chain)

1. **The model/save layer is innocent.** A bare `container.mainContext` with no `@Query` and no view tree:
   inserting an untouched bystander `Playlist`, then saving an *unrelated* `PlaylistFile` or `GlobalSettings`,
   never re-fires the bystander's setters — in-memory *or* on-disk SQLite. (`ObjectRefaultReproductionTests`.)
   So a plain `save()` does not refault registered objects.

2. **`@Query` is the driver.** In the running app, an overlay harness roots a probe tree where no ancestor
   observes the watched `Playlist`, so a wake can only be that instance's own observation firing. With the
   sidebar `@Query<Playlist>` **present**, saving an unrelated `PlaylistFile` *or* `GlobalSettings` woke every
   `Playlist` probe including an app-untouched bystander. With `@Query<Playlist>` swapped for a one-shot
   snapshot, the same saves woke **only** the one changed object (the file cell) — the `Playlist` refault
   vanished.

3. **It is generic to `@Query`, not specific to `Playlist`.** Adding a live `@Query<Tag>` (a model with *no*
   Codable composite field) made an independently-fetched `Tag` instance refault on the same unrelated saves.
   So the Codable composite attributes on `Playlist` were never the cause — any `@Query` does this to its own
   entity's instances.

`setIfChanged` on the derived-fact writers (`file.merge` of `duration`/`width`/`height`/`fileSizeBytes`/
`fingerprint`) is worthwhile hygiene — it drops no-op writes so they never dirty/save — but it is **not** the
fix: a genuinely-changed write dirties the context identically, and the ~5s `lastPosition` save is a real
change. The fix has to remove the `@Query` amplification.

## Fix — settled design

Both `@Query(sort: \Playlist.sortOrder)` sites become a **plain fetch, read in the body** and gated by an
observed signal. No memoizing provider type: the playlist set is a handful of rows and the two views are the
only consumers — a `PlaybackSequences`-style cache would be more machinery than the fetch it saves. No view
`@State` + `.onChange` either: `AppState.playlists(ofType:)` reads `playlistsVersion` before fetching, so the
version read *is* the Observation dependency and the body re-runs exactly when the set changes — the same
shape as the existing `sequences.version` accessors.

- `AppState.playlistsVersion: Int` — `private(set)`, written only through `notePlaylistsChanged()`, bumped by
  playlist CRUD and by the file create/delete paths (the latter because the rows show `fileCount`).
- `AppState.playlists(ofType:)` — the accessor both lists call; one media type, section order.
- `PlaylistSidebar` / `LibrarySurface` bind the snapshot once per body and share it between the list and its
  empty state. The two views keep their own list chrome: the row bodies are alike, but the sidebar's rename /
  contextMenu / `.onMove` / sidebar style and the library column's `+` footer diverge enough that a shared
  list view would need a fistful of flags and two `@ViewBuilder`s to reconstitute both.

**Rejected: a `@ModelActor` snapshot provider.** A model actor is a second `ModelContext`; it drives no
SwiftUI update on its own (the refresh signal still has to be built by hand), its models can't cross into the
main context, and its background writes propagate unreliably. The cost here was never the fetch — ~10 rows on
the main actor — it was the invalidation, which only removing the live `@Query` fixes.

### Bump sites for `playlistsVersion`

| Path | Why |
|---|---|
| `AppState.makePlaylist` | new playlist row |
| `AppState.delete(_ playlist:)` | removed row + `compactSortOrder` renumber |
| `AppState.rename(_:to:)` | row label |
| `AppState.reorder(_:fromOffsets:toOffset:)` | section order |
| `AppState.deleteFiles(_:)` | `fileCount` |
| `AppState.applyScanResult` (when `result.changed`) | `fileCount` after a rescan prunes/appends |

Deliberately **not** bumped: filter/tag/position saves and every other `persistAndRefresh` caller — none of
them changes the playlist set or a file count, and bumping there would re-create a smaller version of the
storm.

### `fileCount` is the trap this exposes

`Playlist.fileCount` is a `fetchCount` inside a computed property, so it is not Observation-tracked (see the
`CLAUDE.md` rule). Today it only looks live because the `@Query` storm re-renders the sidebar constantly.
With the storm gone the file create/delete paths must bump — but the bump alone is not enough: it wakes the
list body, which then rebuilds an identical `ForEach` value and SwiftUI keeps the rows. The count needs a
reader that registers the gate where the count is shown (step 10).

## Steps

1. **Done.** Characterization on the unchanged code (`PlaylistSnapshotRefaultTests`): a plain
   `fetch(FetchDescriptor<Playlist>())` does **not** re-fire an untouched registered `Playlist`'s observation,
   and it preserves a pending unsaved rename — so the replacement snapshot can neither storm on its own
   signal nor clobber an in-flight inline rename.
2. **Done.** `AppState.playlistsVersion` + `notePlaylistsChanged()` + `playlists(ofType:)`, with
   `PlaylistsVersionTests` covering all six bump sites and the two saves that must not bump. Observed red on
   the six before the bumps were added, green after.
3. **Done, verified in the app.** Both `@Query` sites removed; the app now mounts none. The by-hand CRUD
   pass — add / rename / reorder / delete a playlist, rescan, delete a file — found one stale surface, the
   row's file count after a file delete; step 10.
4. **Done.** Rationale lives in `AppState.playlistsVersion` / `playlists(ofType:)` and in each view's body
   comment; `doc/architecture.md` records the no-`@Query` rule for the Manager shell.
5. **Done.** Measured what remained (instrumentation below). Reading of a ~12 s scroll:
   - The chrome is quiet. `RootView`, `ManagerView`, `PlaylistSidebar`, `PlaylistCenterView`,
     `FileCollectionView`, `FilterBar`, `CenterActionsBar`, `AudioInlet` each evaluated their body
     **once**, at startup, and never again while ~40 saves/second landed. The `@Query` amplification is
     gone in the app, not just in the tests.
   - What remained was per-cell: `cell.task 35–43`, `merge no-op 35–42`, `save GalleryCell.swift 35–42`,
     `merge changed 0`, `cell.metadataPass 0` — every second of scroll. Not one merge changed a fact,
     and each was followed by a real save on the main actor. `GalleryCell 60–147` against
     `FileGalleryCell 15–70`: cells re-rendered ~2–3× per appearance, the extra ones their own writes
     firing back at them.
6. **Done.** `setIfChanged`. The gallery serves a cell from the disk
   thumbnail cache, whose hit path always reports `fileSizeBytes` + `lastModified`
   (`ThumbnailService.produceData`); `merge` assigned them unconditionally, and SwiftData dirties a
   record on an equal write exactly as on a real one. So a scroll over fully-cached files wrote,
   dirtied and saved once per cell for facts that never moved.
   - `PersistentModel.setIfChanged(_:to:)` — assigns only on a difference.
   - `PersistentModel.trySave` gates on `modelContext?.hasChanges`, so a sink that restated known facts
     leaves the context clean and the save is skipped once, here, rather than at each call site — the
     producers keep calling `merge` then `trySave` unconditionally.
   - `PlaylistFile.merge` routes every field through `setIfChanged`; `HDRCache.record` (both sinks) and
     `CloudFileService.apply` — the other derived-fact writers on repeated paths — do the same. The
     cloud feed re-reports unchanged files on every update.
   - `MediaMetadataServiceTests.mergingIdenticalFactsLeavesTheRecordClean` was observed red on the
     unchanged code (`context.hasChanges → true`), with `mergingAChangedFactDirtiesTheRecord` green as
     the control; both green after.

   - Verified in the app. Across a ~20 s scroll **not one `save …` line** was logged, while `merge`
     kept running at 77–160/s — the sink is called exactly as often, it just no longer dirties the
     context. The chrome stayed silent for the whole scroll (no `RootView` / `ManagerView` /
     `FileCollectionView` / `FilterBar` line after startup), so step 3 holds under load too.

7. **Open — the remaining cost is per-cell, not invalidation.** Scroll is still not smooth with the
   storm gone. Per second of scroll the same run reads `FileGalleryCell 57–168` (≈ one body per cell
   appearance, correct), `cell.task 71–155` (≈ one task per appearance, so the `.task` id is stable
   and not re-firing), and `GalleryCell 158–322` — **~2–2.4 bodies per appearance**. One extra is the
   `image` `@State` write landing; the rest is unattributed. `cell.memoryHit` is near zero even
   scrolling back (13/90 in one sample, 21/99 in another), so nearly every appearance goes to the
   disk cache and decodes.

   `_printChanges` on `GalleryCell`, with the file name printed alongside so evaluations can be
   paired by cell, resolves the shape but not the cause. Per 7 newly appearing cells (one grid row):

   | Attribution | Cells |
   |---|---|
   | `@self, @identity, _thumbnails, _metadataService, _hdrCache, _appState, _browsingFolderURL, _image` | the 7 new cells — first evaluation |
   | `@self, @identity, _image` | the same cells minus one, immediately after |
   | `_image` | those cells again, one window later — the thumbnail landing |

   `FileGalleryCell` evaluates exactly once per cell throughout, so the extra evaluation happens
   **without the parent rebuilding it**. It is contiguous within a row (all but the first cell in one
   sample, only the last in another) and reports no environment change — consistent with SwiftUI
   re-evaluating during row layout, which `_printChanges` cannot attribute further.

   Two per cell is the floor (placeholder, then image); the third is the waste — ~30% of gallery body
   evaluations on forward scroll.

   **Refuted: the extra evaluation is the in-memory cache hit landing synchronously in `.task`.**
   Logging the file name on each `cachedThumbnail` hit put every hit in the *back-scroll* section,
   where body evaluations are ~0 (`cell.memoryHit 13  cell.task 13  GalleryCell 1` over 3.9 s); the
   forward-scroll windows that produce the double render record no memory hits at all.

   Also established: **revisited cells are not rebuilt.** Scrolling back over cells already seen
   re-fires `.task` (serving from the memory cache) with no `GalleryCell` / `FileGalleryCell`
   evaluation at all, so this cost is confined to a cell's first appearance.

   Counters and `_printChanges` are exhausted: they say how many bodies run, not whether that is
   where the wall-clock goes. The other per-cell cost is unmeasured and may well dominate — step 9
   settles that every appearance is a disk read plus a decode, 1880 out of 1880. Sizing it needs a
   fresh Instruments trace per `doc/profiling.md` (host Mac, attach to the Debug build's pid), read
   for its Hangs lane and time profiler; the original trace predates steps 1–6 and no longer
   describes this code.

8. **Own the thumbnail's `@State` in a leaf, not in the tile. Done, verified in the app.**
   In a settled library the
   only thing a scroll changes per cell is `image`: placeholder → loaded. The metadata a decode
   reports is already on the record, so every `fill` is a `setIfChanged` no-op and nothing else on the
   tile is invalidated. `_printChanges` bears this out — the extra evaluation reports `_image` alone,
   with no other input named.

   But `image` is a `@State` of `GalleryCell`, so that one write re-runs the entire tile body: the
   caption, the selection background, the four badge overlays, the border, the scrim — none of which
   depend on it.

   `GalleryThumbnailImage` is that leaf: it owns `@State image`, the `.task`, `thumbnailKey`, and
   `recordMetadata`, and draws the rounded rect plus the image-or-placeholder. `GalleryCell.thumbnail`
   applies the badge / border / scrim overlays to *that* view. Overlays attached in the parent are
   part of the parent's view value, so the child's `@State` write does not re-run them.

   Per appearance: `GalleryCell` once, `GalleryThumbnailImage` twice — and the second is a rect with
   one `Image`, not the tile. Badge invalidation stays possible (a first scan of a fresh folder does
   fill metadata) but is then a real change, and rare.

   `thumbnailKey` and `recordMetadata` moved with the state they serve, so their tests moved with them
   — `GalleryCellTests` became `GalleryThumbnailImageTests`, and `CloudRefreshKeyTests` builds the leaf
   for its key assertion. Both were green on the unchanged code and green after, which is what makes
   this a refactor rather than a rewrite. Full suite: 784/786, the two failures being
   `PlaybackEngineTests` cases that pass 39/39 in isolation (the known libmpv-timing flake under
   full-suite load). No new navigator warnings.

   Measured over a 16-window scroll (totals across all windows, per `FileGalleryCell` — one per cell
   appearance, 758 of them):

   | | Before | After |
   |---|---|---|
   | `GalleryCell` | 2.0–2.4× | **1.26×** |
   | `GalleryThumbnailImage` | — | **2.60×** |
   | `merge changed` / `merge no-op` | unknown | **0 / 983** |

   The premise holds outright: not one `merge changed` in the run. Metadata during a scroll is fully
   settled, so the badges stay on the tile and no `GalleryBadges` split is warranted.

   The tile's invalidation collapsed by about two-thirds but not to 1.0. The residual ≈ 0.26 is step
   7's unattributed evaluation — the contiguous-within-a-row one `_printChanges` names no input for —
   which the split was never going to remove.

   `GalleryCell` is constructed only by `FileGalleryCell.body`, so evaluating more often than its
   parent means SwiftUI re-ran a view value it already held: the source is one of `GalleryCell`'s own
   dependencies. Three candidates, all refuted by inspection:

   - **A store write dirtying the `PlaylistFile` the badges read.** `merge changed` is 0 and no `save`
     line appears anywhere in the run — nothing dirtied the context during the scroll.
   - **The HDR sink re-writing `isHDR`/`hdrGamma`/`hdrPrimaries` on every decode.** `HDRCache.record`
     already writes through `setIfChanged`, and would have shown as a `save` line if it moved.
   - **A live `@Query` coarsely refaulting the registered `PlaylistFile`s.** None remains in the app;
     steps 1–4 removed both, and `PlaylistSidebar` / `LibrarySurface` carry comments saying why.

   So it has no store-side source, which is consistent with `_printChanges` naming no input. What is
   left is SwiftUI's own layout negotiation (the tile's `aspectRatio(.fit)` inside an equal-width grid
   column), and `_printChanges` cannot see that.

   **There is no tool left that can name it.** The route would be `analyze_trace.py --fanin-for
   "GalleryCell"`, which ranks the source nodes driving a view's updates — but it reads the
   `swiftui-causes` lane, and that lane has come back empty in every trace recorded for this app
   (now stated as fact in `doc/profiling.md`). A trace can size the scroll; it cannot attribute this.
   Note the size of the prize before spending anything further on it: 0.26 extra evaluations of a
   body with no decode in it, against 983 disk reads in the same run.

   What this does *not* claim is a speed-up. Total body evaluations rose: 2.2 tile bodies per
   appearance became 1.26 tile + 2.60 leaf. What improved is the mix — the expensive body (four badge
   overlays, border, scrim, caption, background) runs 1.26× instead of 2.2×, and the extra evaluations
   landed on a body that is a rounded rect and one `Image`. A body count, not wall-clock.

9. **The in-memory thumbnail cache is redundant with the disk cache. Removed.**
   The same run settles the counters exactly: `merge no-op` (983) + `cell.memoryHit` (16) =
   `cell.task` (999), and `merge` runs only on the produce branch. So **1.6% of displays hit memory**;
   the rest went to disk.

   That is not merely the expected forward-scroll behaviour. The back-scroll windows — where the cache
   exists to help — read `cell.task 139  cell.memoryHit 11`: 8%. At ~200 entries (128 MB ÷ ~0.6 MB per
   440 px decode) the cache had already evicted what the user scrolled back to. It is both unused
   going forward and too small going back.

   `ThumbnailService.memoryCacheEnabled = false` disables the layer at its three sites (the sync
   `cachedThumbnail` pre-check, the async re-check, the store). The whole test suite passes unchanged
   with it off — no test ever depended on the memory layer, which is itself evidence of how little it
   carries.

   To make the fallback readable, `produceData` now counts `thumb.diskHit` vs `thumb.sourceDecode`.
   That split is what decides the experiment: if the produce path is overwhelmingly `diskHit`, the
   fallback is a small read plus a decode and the memory layer can go for good, reclaiming the 128 MB
   ceiling and ~30 lines (`memory`, `memoryKey`, `byteCost`, `cacheByteBudget`, `cachedThumbnail`, and
   the leaf's sync pre-check). A material `sourceDecode` share means the disk cache is missing too, and
   the memory layer is masking that rather than the other way round.

   Expected, stated before the run: no perceptible change on forward scroll (98.4% already miss); a
   placeholder flash on the ~1.6% of revisits that used to paint instantly; footprint ceiling down by
   up to 128 MB.

   **Result, over 1737 cell appearances with the layer off.** The counters land on one number:

   | `cell.task` | `thumb.diskHit` | `thumb.sourceDecode` | `merge no-op` | `merge changed` |
   |---|---|---|---|---|
   | 1880 | 1880 | **0** | 1880 | 0 |

   Every display was task → produce → disk hit → merge nothing. Not one source decode in the run, so
   the work the memory layer would have spared was a disk read that hit every single time. It was
   redundant with the disk cache, not additive to it — a 128 MB ceiling bought a 1.6% saving on a cost
   the disk cache already absorbs.

   Body ratios are unchanged with it off (`GalleryCell` 1.26× → 1.22×, `GalleryThumbnailImage` 2.60× →
   2.32× per `FileGalleryCell`), confirming the layer was structurally inert.

   Removed: `memory`, `cacheByteBudget`, `memoryCacheEnabled`, `byteCost`, `memoryKey`,
   `cachedThumbnail` (whose only caller was the leaf), and the leaf's sync-vs-async branch — which
   collapses `GalleryThumbnailImage.task` to a straight line. The disk cache keeps its own
   invalidation (content fingerprint) and its warmth across launches, which is what the measurement
   shows doing the actual work.

   Docs corrected to match: the `ThumbnailService` header (two-tier → one), `doc/architecture.md`'s
   ThumbnailService entry, and `AppConstants.galleryThumbnailPixelSize`, which no longer sizes a
   memory budget. Suite green (37/37 over `ThumbnailServiceTests`, `GalleryThumbnailImageTests`,
   `CloudRefreshKeyTests`) both with the layer inert and after deleting it; no test ever depended on
   it, which is its own evidence. No new navigator warnings.

   `cell.memoryHit` retired with the layer; `thumb.diskHit` / `thumb.sourceDecode` stay until the
   instrumentation comes out.

10. **A bump wakes the list body but not its rows — the sidebar count needs its own reader. Fixed,
    verified in the app.**
    Step 3's in-app CRUD pass found it: playlist add / rename / reorder / delete are fine, a rescan
    updates the row's file count, a file delete does not.

    `PlaylistsVersionTests.deletingFilesDropsTheBadgeCount` (added, run against the unchanged code)
    comes up **green**: `deleteFiles` bumps the version and the count fetch answers the new number. So
    the model seam was never the problem, and the defect is above it.

    Measured in the app with a `sidebar.row` counter next to the existing ones. One file delete:

    ```
    PlaylistSidebar: \AppState.playlistsVersion changed.
    [render] 4.0s  … PlaylistSidebar 2 …  notePlaylistsChanged 1  persistAndRefresh 1
    ```

    `sidebar.row` **absent**. The rescan window for comparison — `sidebar.row 8 … PlaylistSidebar 1`,
    attributed to `\AppState.busyPlaylistIDs changed`, a property read *inside* the row, which
    invalidates each row directly. That is why the rescan looked fine: it never needed the version to
    reach the rows.

    Mechanism: the bump re-runs `PlaylistSidebar.body`, which rebuilds `ForEach(playlists) { row($0) }`
    from the same `Playlist` references and an unchanged closure. The value is identical, so SwiftUI
    keeps the rows it has and the untracked `fileCount` fetch is never re-read. The gate was registered
    in the body, but the count is displayed in a row the body does not re-evaluate.

    Fix: `PlaylistRowBadge`, a leaf owning the whole trailing accessory (deleting spinner / busy
    spinner / count), reading the gate itself through `AppState.fileCount(of:)`. The bump now
    invalidates the badge directly, so the count re-reads while the row around it stays put — a
    contained boundary rather than a wider re-render. It also folds the accessory, duplicated verbatim
    in `PlaylistSidebar.row` and `LibrarySurface.playlistRow`, into one view; both surfaces had the
    identical bug. Corrected the "`fileCount` is the trap this exposes" note above, which assumed the
    refetch re-runs the row bodies. 26/26 green, no new navigator warnings.

## Instrumentation — removed

The counters are out of the tree: `ShuTaPla/Debug/RenderLog.swift`, the `Self.logBody` calls on the
chrome and per-item views, and the `RenderLog.note` write sites (`trySave`, `merge`,
`persistAndRefresh`, `notePlaylistsChanged`, `sequences.bump`, `persistTimelinePosition`,
`GalleryThumbnailImage.task`, `ThumbnailService.produceData`, `PlaylistSidebar.row`,
`PlaylistRowBadge`). `trySave` lost its `#fileID`/`#line` arguments and `merge` its `changed`
bookkeeping — with nothing reading the result, `setIfChanged` returns `Void`. The evidence they
produced is quoted in the steps above; the code itself is recoverable from git history.

They answered what they could answer — how many bodies run and what invalidated them — and both
open questions are past that: the residual ≈ 0.22 `GalleryCell` evaluations that `_printChanges`
names no input for, and the wall-clock of the per-appearance disk read plus decode. Neither is a
counting question, so the counters stay out unless a new invalidation question appears.
