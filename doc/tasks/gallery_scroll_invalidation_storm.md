# Task — Gallery scroll invalidation storm

**Status: complete.** All ten steps done and verified in the app; the gallery scroll is smooth and
`GalleryCell` evaluates once per cell appearance. The instrumentation that drove the investigation
has been removed. Steps are numbered in the order they were planned, not the order they were
finished — step 7 was the last to close, so steps 8–10 refer back to it as open.

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

7. **Done — the extra bodies were an alignment guide descending into the tile; `GalleryCell` is now
   at 1.01 bodies per appearance and the scroll is smooth.**

   Where the step started: with the storm gone the scroll was still jerky, and per second of scroll
   the same run read `FileGalleryCell 57–168` (≈ one body per cell appearance, correct),
   `cell.task 71–155` (≈ one task per appearance, so the `.task` id is stable and not re-firing), and
   `GalleryCell 158–322` — **~2–2.4 bodies per appearance**. One extra was the `image` `@State` write
   landing, which step 8 moved to a leaf; the rest was unattributed. `cell.memoryHit` was near zero
   even scrolling back (13/90 in one sample, 21/99 in another), so nearly every appearance went to the
   disk cache and decoded — which step 9 then measured exactly.

   The sections below are the search in the order it ran: what `_printChanges` could and could not
   see, the two instrumented stages, the named cause, and the fix.

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

   Two per cell was the floor for the tile as it then stood — placeholder, then image — so the third
   was waste, ~30% of gallery body evaluations on forward scroll. Step 8 moved `image` down to a leaf,
   which drops the tile's own floor to one.

   **Refuted: the extra evaluation is the in-memory cache hit landing synchronously in `.task`.**
   Logging the file name on each `cachedThumbnail` hit put every hit in the *back-scroll* section,
   where body evaluations are ~0 (`cell.memoryHit 13  cell.task 13  GalleryCell 1` over 3.9 s); the
   forward-scroll windows that produce the double render record no memory hits at all.

   Also established: **revisited cells are not rebuilt.** Scrolling back over cells already seen
   re-fires `.task` (serving from the memory cache) with no `GalleryCell` / `FileGalleryCell`
   evaluation at all, so this cost is confined to a cell's first appearance.

   Counters and `_printChanges` are exhausted: they say how many bodies run, not whether that is
   where the wall-clock goes. The two stages below close that gap without a trace.

   ### Catching the residual — plan

   **`_printChanges` naming no input is not the same as there being no cause.** It names *inputs*:
   `@self`, `@identity`, and property wrappers (`_draftName`, `_appState`). `GalleryCell.body` reaches
   six `PlaylistFile` fields through a plain `let file: PlaylistFile` — `pixelSize` (i.e. `width` +
   `height`), `isHDR`, `cloudStatus`, `fileSizeBytes`, `duration`, `fileName`. An invalidation arriving
   through the Observation registrar on one of those is not an input that differs, so `_printChanges`
   has nothing to name. The residual's signature is exactly what that blind spot produces.

   That has to be squared with step 8, which found the store silent (`merge changed` 0, no `save`
   lines). The two coexist only if something fires Observation without our code writing a new value —
   a refault does that, and so does an equal write — or if the residual is genuinely SwiftUI-internal.
   So the first move is not to guess between them but to **split the residual in two**.

   **Stage 1 — an Observation probe mirroring the body's read set.** Arm `withObservationTracking`
   over the same six accessors the body reads and count what fires. `withObservationTracking` records
   reads transitively, so `_ = file.pixelSize` picks up `width`/`height` on its own: the probe's
   tracked set is identical to the body's *by construction*, not by a list kept in sync by hand. It is
   one-shot, so it re-arms after each fire, and it snapshots the six values at arm time — the diff on
   re-arm names the field that moved, or reports that **none did**, which is the refault/equal-write
   signature and is invisible to every other tool here.

   The decision rule, against the restored `GalleryCell` / `FileGalleryCell` body counters (same
   harness as steps 8–9, so the ratios compare directly with 1.22× / 2.32×):

   - probe fires ≈ the residual → it *is* the model. The label names the keypath, and the writer is
     then a symbolic breakpoint on that setter.
   - probe fires with no field moved → a refault or an equal write. Step 8's three refuted candidates
     were all about *changed* values, so this reopens them on different terms.
   - probe silent while the extra bodies happen → not the model at all, and the refault theory dies
     with it. Only then is stage 2 worth anything.

   **Stage 2, only if the probe stays silent — capture the stack, don't count.**
   `Thread.callStackSymbols` inside the body, sampled into a set of distinct stacks and dumped on
   demand. The frames above `GalleryCell.body` separate the two survivors: a layout-driven evaluation
   arrives under `sizeThatFits`/`LayoutComputer`, a graph update under `ViewRendererHost.render` →
   `AG::Graph::UpdateStack::update`. That is the discriminator for the `aspectRatio(4.0/3.0, .fit)`
   hypothesis, and a handful of distinct stacks carries more than any count could.

   Ablation (swap the aspect box for a fixed height, re-count) is the *confirmation* once there is a
   suspect, not the search — it can only test one guess per run.

   The prize is unchanged and small: ≈ 0.22 extra evaluations of a body with no decode in it, against
   983 disk reads in the same run.

   ### Stage 1 — measured

   Nine windows of a scroll: **`GalleryCell` 71, `FileGalleryCell` 61** — the residual is intact and
   the ratio (1.16×) sits with the 1.22× of steps 8–9. **No `probe.*` line appeared at all.**

   Two windows are the shape of the thing: `4.8s GalleryCell 1` and `12.6s GalleryCell 1` — a tile
   body with no parent body anywhere in the window. The child re-evaluates on its own.

   That is the third branch, so the model is out and the refault theory with it. One caveat is being
   closed before the null is spent: a probe that never fires and a probe that never armed look
   identical in the log, so `watchTile` now counts `probe.armed`. A run with `probe.armed` present
   and no `probe.<field>` is a real null; a run with neither means the instrument never ran and says
   nothing about the model.

   Stage 2 is therefore live, with a sharper discriminator than the layout/graph one. A `GalleryCell`
   body driven by its parent carries `FileGalleryCell` in its call stack; a residual one does not.
   `BodyStackProbe` splits every body evaluation on that (`GalleryCell.fromParent` vs
   `GalleryCell.standalone.<layout|graph|other>`) and prints each distinct standalone stack once in
   full. The standalone count is a prediction: it should land on the gap, ≈ 10 in the run above. If it
   does, the residual is defined by a stack rather than inferred from a subtraction, and the frames
   above the body name the driver.

   ### Stage 2 — measured: the residual is layout-driven

   The prediction was wrong in a way that settled the question anyway. **`fromParent` never appears —
   every tile body is `standalone`**, and `standalone.graph + standalone.layout` equals `GalleryCell`
   exactly (6+4=10, 9+6=15, 3+2=5). A child body is not evaluated inside its parent's body call: the
   parent body only builds the view value, and the graph evaluates the child later from its own root,
   so `FileGalleryCell` can never be in that stack. **The `GalleryCell` / `FileGalleryCell`
   subtraction used through steps 8–9 was a proxy, not a partition.** `FileGalleryCell` remains a
   sound denominator — one body per cell appearance — so the ratio still measures how many tile
   bodies an appearance costs; what the subtraction cannot do is say which bodies the excess consists
   of. Only the stacks can.

   The secondary classification carried the run. Six consecutive steady windows:

   ```
   GalleryCell 10  =  standalone.graph 6  +  standalone.layout 4
   FileGalleryCell 6      probe.armed 6
   ```

   `graph` == `FileGalleryCell` == `probe.armed` throughout. Six tiles come on screen, each takes one
   graph-driven body — the legitimate one — and **four further bodies arrive under
   `sizeThatFits`/`LayoutComputer`**. That is the residual, and it is layout, not Observation:
   `probe.armed` is present in every window and no `probe.<field>` ever fired, so the model null is a
   real null rather than an unarmed instrument.

   What this narrows to: a measurement pass does not re-run a body on its own — layout queries an
   already-built tree. A body re-running under `LayoutComputer` means the tile's content depends on a
   layout-provided value. `aspectRatio(4.0/3.0, .fit)` is one candidate; `GeometryReader`,
   `ViewThatFits`, and `containerRelativeFrame` are the constructs that actually force it. The
   distinct `standalone.layout` stacks name which, and ablation then confirms.

   ### The stack: a scroll-geometry preference pulls the tile bodies

   A captured `standalone.graph` stack, innermost frame outward:

   ```
   2   GalleryCell.body
   3-7 ViewBodyAccessor.updateBody → DynamicBody.updateValue
   13  DynamicPreferenceCombiner.info
   14  DynamicPreferenceCombiner.value
   20  LazyPreference.value
   21  ScrollGeometryPreferenceKey.reduce(value:nextValue:)
   28  LazyPreference.value
   34-40 ViewGraphRootValueUpdater.render → NSHostingView.layout
   ```

   The body is demanded as a **dependency of a `ScrollGeometryPreferenceKey` reduction**, during the
   hosting view's render pass off the AppKit display cycle — not by its parent and not by the model.
   The declaration is `PagedList.swift:181`:

   ```swift
   .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset.y = y }
   ```

   The reference-box reasoning above that line is sound as far as it goes — the *container's* body
   stays inert. What it misses is that the modifier installs a preference on the `ScrollView`, and a
   preference reduces up the subtree: the cost lands on every resident tile the reduction pulls, not
   on the view that declared it.

   Two corrections this forces:

   - `standalone.graph` was assumed to be the legitimate evaluation. This stack is graph-classified
     (the `_layoutSubtree` frames are AppKit's; SwiftUI's `LayoutComputer`/`sizeThatFits` are absent)
     and is preference-driven. The graph/layout cut is weaker than the preference chain it exposed.
   - Not yet confirmed as *the* residual. This stack was captured on page arrival, and a first body
     evaluation must be demanded by something — the combiner may just be the first consumer to ask.
     The `standalone.layout` stacks discriminate: through `ScrollGeometryPreferenceKey` too → one
     cause, and ablating the modifier is the check; through `sizeThatFits` on the tile frame → two
     independent causes.

   A second capture settles the first of those. It is frame-for-frame identical through frame 40,
   differing only in how the runloop entered (observer callback vs source0): **the graph path is a
   single shape.** And it scales with tile *arrival* — across seven windows `graph` tracks
   `FileGalleryCell` and `probe.armed` (9/8/7, 7/9/8, 9/9/9, 11/10/12, 13/14/12), one graph body per
   newly resident tile. So the preference combiner is the *demand path* for a first evaluation that
   had to happen anyway, not extra work. `onScrollGeometryChange` still makes the reduction walk the
   subtree, but it is not the residual.

   The residual is the `layout` bodies, steady at ≈ 0.7 per arriving tile.

   ### The residual, named: an alignment guide descends into the tile

   Five distinct `layout` stacks; four share one shape. Outermost to innermost:

   ```
   79  LazyVStackLayout.sizeThatFits                  ← PagedListPage.content
   75  LazyStack.measureEstimates(updatingPosition:index:minor:subviews:cache:)
   67-73 ForEachState.applyNodes → ForEachList.applyNodes
   56  LayoutEngine.lengthThatFits(_:in:)
   52  _FlexFrameLayout.sizeThatFits                  ← .frame(maxWidth: .infinity)  (row)
   47  _FrameLayout.sizeThatFits                      ← .frame(height: rowHeight)
   41  _PaddingLayout.sizeThatFits                    ← .padding(.horizontal, spacing)
   35  _FlexFrameLayout.sizeThatFits                  ← .frame(maxWidth: .infinity)  (gridRow)
   26-30 StackLayout.placeChildren → sizeChildrenGenerally… → resize   ← the row HStack
   25  ViewDimensions[AlignmentKey]
   22-24 UnaryLayoutEngine.explicitAlignment → childPlacement
   20-21 _FrameLayout.placement                       ← cell(id).frame(width:height:alignment:.top)
   19  LayoutProxy.dimensions(in:)
   13  UnaryLayoutComputer<_PaddingLayout>.updateValue ← GalleryCell's .padding(3)
   2   GalleryCell.body
   ```

   **Resolving an alignment guide descends into the child.** The row `HStack` in
   `GalleryPagedList.gridRow` must align its cells vertically, so it reads `ViewDimensions` for the
   alignment key. The fixed `.frame(width: tileWidth, height: tileHeight, alignment: .top)` does not
   terminate that query: a frame answers `explicitAlignment` by asking whether its child defines a
   guide, and asking requires the child's dimensions — hence the body. The tile's size being known
   statically is irrelevant; it is the *guide* being resolved, not the size. The fifth stack (#0) is
   the plain sizing variant, `_PaddingLayout.sizeThatFits` descending through `GalleryCell`'s own
   `.padding(3)`.

   Two candidates die here. `onScrollGeometryChange` is the `graph` path — one body per arriving
   tile, the legitimate first evaluation. `aspectRatio(4.0 / 3.0, .fit)` appears in none of the five
   stacks.

   `measureEstimates` walking `ForEach` subviews could have meant O(rows per page) rather than
   O(visible). The counts rule that out: `layout` holds at ≈ 0.7 × arriving tiles in every window, so
   it is incremental.

   ### Fix — terminate the alignment query at a leaf

   The body is not cheap enough to accept the residual: each evaluation makes six `@Model` reads
   through the Observation registrar, formats three strings, and builds four overlay subtrees.

   The descent happens because the `HStack`'s subview is the tile itself, so resolving the vertical
   alignment guide has to reach `GalleryCell.body`. Make the subview a fixed-size leaf instead and
   hang the tile off it as an overlay: overlay geometry is defined entirely by its primary, so the
   guide resolves against `Color.clear` and the tile is laid out inside an already-resolved frame.

   `Color.clear` is hit-testable in SwiftUI, and `rowHeight` is deliberately generous (`GalleryGrid`
   notes the slack "falls harmlessly below the caption"), so the leaf must be
   `.allowsHitTesting(false)` — otherwise it would swallow clicks in the slack below a tile that the
   current `.frame(alignment: .top)` leaves inert.

   There is no unit-testable seam here — the descent is a property of SwiftUI's layout engine, not of
   our code. The confirmation is the counter measurement against the baseline already recorded above
   (`layout` ≈ 0.7 × arriving tiles): the `standalone.layout` count should collapse, with
   `standalone.graph` unchanged at one per arriving tile. If it merely moves the descent one level
   down, the leaf-termination theory is refuted and a custom `Layout` placing tiles at computed
   offsets — the geometry `GalleryGrid` already knows — is the remaining fix.

   ### Fix — measured, confirmed

   `GalleryPagedList.gridRow` now packs `Color.clear.allowsHitTesting(false).frame(width:height:)`
   with `.overlay(alignment: .top) { cell(id) }` instead of framing the cell directly; the rationale
   above is recorded on the method's doc comment, since it is the kind of thing a later reader would
   otherwise "simplify" straight back into the direct frame.

   Measured over a 17-window scroll:

   | | Before | After |
   |---|---|---|
   | `GalleryCell` per `FileGalleryCell` | 1.26× | **1.01×** (401 / 396) |
   | `standalone.layout` | ≈ 0.7 × arriving tiles | **1**, in the first window |
   | `standalone.graph` | 1 × arriving tiles | unchanged, 1 × arriving tiles |

   The alignment descent is gone outright, and every surviving body is the legitimate first
   evaluation — `graph`, `FileGalleryCell`, and `probe.armed` move together window by window. One
   body per cell appearance is the floor, so the counter is closed.

   The scroll *feels* worse under instrumentation than it will shipped: `BodyStackProbe.note` calls
   `Thread.callStackSymbols` on every body evaluation, `dladdr`-symbolicating ~100 frames ~400 times
   in that scroll. It skews the felt cost, not the counts.

   With the harness out, the scroll is smooth — confirmed in the app.

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

   The tile's invalidation collapsed by about two-thirds but not to 1.0. The residual ≈ 0.26 is the
   evaluation step 7 went on to name — contiguous within a row, `_printChanges` naming no input for
   it — which the split was never going to remove.

   `GalleryCell` is constructed only by `FileGalleryCell.body`, so evaluating more often than its
   parent means SwiftUI re-ran a view value it already held: the source is one of `GalleryCell`'s own
   dependencies. Three candidates, all refuted by inspection:

   - **A store write dirtying the `PlaylistFile` the badges read.** `merge changed` is 0 and no `save`
     line appears anywhere in the run — nothing dirtied the context during the scroll.
   - **The HDR sink re-writing `isHDR`/`hdrGamma`/`hdrPrimaries` on every decode.** `HDRCache.record`
     already writes through `setIfChanged`, and would have shown as a `save` line if it moved.
   - **A live `@Query` coarsely refaulting the registered `PlaylistFile`s.** None remains in the app;
     steps 1–4 removed both, and `PlaylistSidebar` / `LibrarySurface` carry comments saying why.

   So it has no store-side source, which is consistent with `_printChanges` naming no input. That
   leaves SwiftUI's own layout negotiation, which `_printChanges` cannot see. The specific guess made
   here — the tile's `aspectRatio(.fit)` inside an equal-width grid column — was wrong: step 7's stack
   capture found an alignment guide resolving into the tile, with `aspectRatio` in none of the layout
   stacks. Right layer, wrong construct.

   **No Instruments trace could have named it.** The route would be `analyze_trace.py --fanin-for
   "GalleryCell"`, which ranks the source nodes driving a view's updates — but it reads the
   `swiftui-causes` lane, and that lane has come back empty in every trace recorded for this app (now
   stated as fact in `doc/profiling.md`). A trace can size the scroll; it cannot attribute this. What
   did attribute it was `Thread.callStackSymbols` sampled inside the body — step 7, stage 2.

   What the inspection above does *not* rule out is a cause the tooling cannot see rather than one
   that isn't there: `_printChanges` names inputs, and the badges read the `PlaylistFile` through a
   plain `let`. Step 7's plan splits that question with an Observation probe, which came back a clean
   null and took the model out.

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

   `cell.memoryHit` retired with the layer, and `thumb.diskHit` / `thumb.sourceDecode` went out with
   the rest of the harness.

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

## Instrumentation

The full harness came out after step 10 — `trySave` lost its `#fileID`/`#line` arguments and `merge`
its `changed` bookkeeping, and with nothing reading the result `setIfChanged` returns `Void`. Those
three simplifications are permanent; the store-write counters are not coming back.

Step 7's own harness — `RenderLog` restored verbatim from git (so its ratios compare directly with
steps 8–9), `Self.logBody` on `GalleryCell` and `FileGalleryCell` as the denominator,
`ObservationProbe` mirroring the tile's model read set, and `BodyStackProbe` classifying each
evaluation's caller — went out with the step. The whole `ShuTaPla/Debug/` directory and
`ObservationProbeTests` are gone; the two views are back to their committed state, so the fix in
`GalleryPagedList` is the only code left standing from this step. 787/787 green (including the two
`PlaybackEngineTests` that flake under full-suite load), no new navigator issues.
