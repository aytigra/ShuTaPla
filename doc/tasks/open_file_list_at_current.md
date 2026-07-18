# Open the file list at the current file

Selecting a playlist, or returning to the Manager from the player, should render the
file list **already positioned at the current file** — no visible travel. Today the
list mounts at the top and then scrolls down to the current file, jarring when the
resume file sits far down (or last).

## Desired behavior

| Trigger | Surface | Want |
|---|---|---|
| Switch to a different playlist (sidebar / overlay selector) | Manager, Visual overlay, Audio overlay | Open **at** current file, no travel |
| Return from player to Manager | Manager | Open **at** current file, no travel |
| App launch (opens in Manager) | Manager | Open **at** current file and highlight it (same as playlist switching does) |
| Scope switch / filter change (list reflows) | Manager | Open **at** current file, no travel |
| Re-click the already-active playlist | Manager, overlays | Instant recenter on the current file |
| Keyboard-move the selection | Manager | Animated scroll-into-view (keep as-is) |

"Current file" = the playlist's playback cursor (`currentFileID`), also the selected/last-played row
after returning from the player. When it is filtered out (or nothing has played), there is no target
and the list opens at the top.

## Failed approaches:

- **`LazyVStack` / `LazyVGrid` + `scrollTo`.** Scrolls smoothly but does not virtualize the *jump*:
  `scrollTo` prefix-walks every row before a far target, so opening deep hitches in proportion to depth.
- **`LazyVStack` + O(1) offset via `scrollPosition` binding.** The only offset control is a **two-way**
  binding SwiftUI writes back every frame → jittery hand-scroll + slow switching. Positioning must stay
  one-way.
- **`List` (NSTableView-backed).** Handles the jump but **is not lazy here** — a row-eval counter showed
  a switch to a ~1440-file playlist builds ~2880 rows (measure + display pass) *before any scrolling*,
  each firing metadata extraction + a model fault. That eager-build is the whole switch/scroll cost.
- **`List` row-type tuning (A1/A2).** Making the row one concrete non-generic type (A1) changed nothing —
  the cost is N rows built, invariant to row type; a cheaper `ForEach` identity (A2, dropped) can't
  reduce N either.

## Completed tasks

**Launch highlight (done, Step 1).** `resolveActivePlaylists()` now appends `reseedManagerSelection()`,
which selects `currentFileID` when it survives the filter and bumps the token — launch highlights the
resume file exactly as a playlist click does.

## Paged gallery/list

A `ScrollView` → `LazyVStack` of **fixed-height pages**
    (`rowsPerPage` grid rows each), each page an inner `LazyVStack` of rows. Keys:
    - The container is **inert on scroll** — it holds no scroll-derived `@State`; `ScrollPosition` is set
      only imperatively for the open-jump, never read in `body`. The `LazyVStack` windows pages natively.
    - **Identity = `[playlist.persistentModelID, columns]`** on the paged content. A playlist switch or a
      column-count (tile-size) change discards the whole tree — no page/cell reuse — so a switch can't
      leave the prior playlist's thumbnails painted and a resize can't reflow under a stale offset; the
      fresh tree rebuilds already positioned on the current file.
    - **`resident` gate.** Each page frames to its fixed `pageHeight` regardless of content, so an empty
      page still reports honest height; pages render `Color.clear` until `isPositioned`, so the open-jump
      lands against the true content height without any page above the target building a cell.

  - [x] **Step 1 — Productionize the paged gallery.** the shape is now a
    reusable `GalleryPagedList<ID, Cell>` in `Views/Shared/GalleryPagedList.swift`, built on a pure
    `GalleryPaging` chunker + `VirtualWindow` (reused at grid-row granularity for content height, the
    open-jump, and the keyboard reveal). Its interface mirrors `VirtualList` (`initialTarget` item
    index + `command`), so `FileCollectionView` routes both surfaces through the same `routeScroll`.
    The container owns the whole `ids` sequence and the chunking — it slices each page's rows itself
    (`ids[items(inRow:)]`) and hands a page only the ids it renders; `GalleryPage` holds no sequence
    and no pager, it just lays the given id slices into rows. Done:
    - `galleryScrollCommand` wired: instant open-at-current + re-click recenter, animated keyboard
      reveal; `fileGridColumns` published from `grid.columns` for the 2D stride.
    - `[playlist.persistentModelID, columns]` identity on the container.
    - `GalleryPaging` covered by `GalleryPagingTests` (12), as the packing helper already is.

- [ ] **Step 2 — Unify both surfaces on one paged core, and clean up.**
  The list surfaces still use the old band-windowed `VirtualList` (re-renders on every scroll-boundary
  crossing); the gallery uses the inert `GalleryPagedList`. Both share nearly the same interface
  (`count`/`rowHeight`/`initialTarget`/`command`/`row`), differing only in implementation and in the
  gallery's grid layer. Unify on the inert paged design and retire `VirtualList`.

  **Design — extract a grid-agnostic `PagedList<Row>` core (Option B).** The shared inert paged-windowing
  machinery moves into `PagedList<Row: View>`: the `ScrollView` → `LazyVStack` of fixed-height pages, the
  `resident` gate, the imperative `ScrollPosition` open-jump, the `isPositioned` reveal, the off-to-the-side
  offset box, and `openInitial` / `apply`. Its interface is a drop-in for `VirtualList`
  (`count`, `rowHeight`, `initialTarget: Int?` row index, `command`, `row: (Int) -> Row`), so the three
  list call sites change by ~a rename. `PagedList` frames each row `.frame(height: rowHeight,
  alignment: .top).frame(maxWidth: .infinity, alignment: .leading)` — grid-free; any inter-row gap is
  baked into `rowHeight` (the row sits top-aligned, gap falls below) and horizontal packing/padding is the
  row content's concern. `GalleryPagedList` becomes a **thin wrapper** that adds only the grid layer:
  `GalleryPaging` chunks ids → grid rows, converts the item-index `initialTarget`/`command` → grid-row
  index (`paging.row(ofItem:)`), and supplies a `row:` closure that slices `ids[items(inRow:)]` into an
  HStack of cells (with the horizontal spacing/padding). The current `GalleryPage` struct is absorbed —
  `PagedList` owns the page.

  Migrate all three list surfaces (Manager `.list`, both overlay `fileList`s in `LibrarySurface`) from
  `VirtualList` to `PagedList`, then delete the `VirtualList` view.

  **Cleanups riding along:**
  - Delete the now-dead `VirtualWindow.visibleRange` / `.firstRow` (only the band version called them) and
    their `VirtualWindowTests` cases.
  - Rename `VirtualWindow` → `PagedListGeometry` (or similar) and `VirtualScrollCommand` → `ScrollCommand`;
    the "Virtual" prefix loses its referent once `VirtualList` is gone. Retitle `VirtualWindowTests`.
  - Collapse the two `@State` scroll commands in `FileCollectionView` (`fileScrollCommand` +
    `galleryScrollCommand`) to one — the list and gallery are mutually exclusive there.
  - Split `FileCollectionLayout`: keep it as just the `list`/`gallery` choice enum; move the gallery grid
    math (`gridMetrics` / `gridLayout` / `rowHeight` + the width/ratio/spacing/chrome constants) into its
    own type (e.g. `GalleryGrid`).
  - Make the gallery cell **self-resolving** like `FileListRow`: a `FileGalleryCell(id:…)` that resolves the
    model in its own body and wraps its own tap / context menu, so `FileCellConfiguration`, `item()`, and
    `galleryCell` all disappear and both surfaces are symmetric "give me an `id` + action closures" cells.

  **Files after:** `Views/Shared/PagedList.swift` (the `PagedList` view + `PagedListGeometry` +
  `ScrollCommand`, renamed from `VirtualList.swift`); `Views/Shared/GalleryPagedList.swift` (`GalleryPaging`
  + the thin `GalleryPagedList` wrapper); `GalleryGrid` for the grid metrics; `FileGalleryCell`. Delete the
  `VirtualList` view.

  **Test-first.** `GalleryPaging` (12) and the surviving `PagedListGeometry` math (contentHeight / offsetY /
  targetOffset / revealOffset) stay unit-tested — rename/trim `VirtualWindowTests`, keep every surviving
  method covered and observe green before and after the rename. The scroll/positioning *feel* is view-layer:
  after the migration verify in-app on a large list playlist and the overlays (open-at-current no travel,
  smooth hand-scroll, keyboard-move animates, re-click recenter) and re-confirm the gallery is unchanged.

  Sub-steps, one at a time, confirmation before each:
  - [x] **2a — Extract `PagedList<Row>`** from the current `GalleryPagedList` paging machinery; re-express
    `GalleryPagedList` as the thin grid wrapper on top of it. Gallery behavior unchanged; build + navigator
    clean; `GalleryPagingTests` green. Done: `Views/Shared/PagedList.swift` holds the grid-agnostic
    `PagedList<Row>` (fixed-height pages, inert scroll, O(1) open-jump, `resident` gate) plus the shared
    pure `FixedChunks` index chunker; `GalleryPaging` is now a thin `FixedChunks(size: columns)` facade and
    `GalleryPagedList` a wrapper that maps item→row and packs each grid row's ids into an HStack. Pure math
    covered by `FixedChunksTests` (page/row chunking at sizes 10/4) + the trimmed `GalleryPagingTests`
    (item↔row); 16 green. `PagedListPage` absorbs the former `GalleryPage`. Still uses the not-yet-renamed
    `VirtualWindow` / `VirtualScrollCommand` (renamed in 2b).
  - [x] **2b — Migrate the list surfaces** (Manager `.list`, both overlays) from `VirtualList` to
    `PagedList`; delete the `VirtualList` view; drop dead `visibleRange`/`firstRow`; rename
    `VirtualWindow`/`VirtualScrollCommand` and retitle their tests. Done: both list call sites
    (`FileCollectionView.fileList`, `LibrarySurface.fileList`) now build `PagedList` — a bare rename,
    the interface already matched. `VirtualList.swift` is deleted; its geometry and command types
    moved into `PagedList.swift` as `PagedListGeometry` (renamed from `VirtualWindow`, minus the
    now-dead `visibleRange`/`firstRow` and the `overscan` field they alone used) and `ScrollCommand`
    (renamed from `VirtualScrollCommand`). All remaining doc/comment references (`AppConstants`,
    `FileRowView`, `FileListRow`, the two views) point at `PagedList`. `VirtualWindowTests` →
    `PagedListGeometryTests` with the band/first-row cases dropped; 13 geometry cases green (29 across
    the paged suites), build + navigator clean. In-app feel verified in 2d.
  - [x] **2c — Structural cleanup:** collapse the scroll-command `@State`s; split `FileCollectionLayout` /
    `GalleryGrid`; introduce `FileGalleryCell` and remove `FileCellConfiguration` / `item()` / `galleryCell`.
    Done: `FileCollectionLayout` is now just the `list`/`gallery` enum; its grid math (`gridMetrics` /
    `gridLayout` / `rowHeight` + the width/ratio/spacing/chrome constants) moved verbatim into a new
    `nonisolated enum GalleryGrid` (`Views/Shared/GalleryGrid.swift`), with `FileCollectionView` /
    `PlaylistSettingsView` / `PlaylistPreferences` repointed. `FileCollectionLayoutTests` → `GalleryGridTests`
    (12 green before and after the move). The two `@State` scroll commands collapsed to one `scrollCommand`
    (list and gallery are mutually exclusive in `FileCollectionView`). New `FileGalleryCell(id:…)` resolves
    the model in its own body and wraps its own tap / context menu — the symmetric twin of `FileListRow` —
    so `FileCellConfiguration`, `item()`, and `galleryCell()` are gone and the gallery hands `GalleryPagedList`
    an `id` + closures like the list does. Build + navigator clean. In-app feel verified in 2d.
  - [x] **2d — Verify in-app** across all three list surfaces and the gallery; navigator clean.
    Done: playlist-switch off-by-a-page fixed by adding `.id(playlist)` remount to the list (both
    Manager and overlay), matching the gallery; the transient "rows under the service-filter strip"
    self-resolved. Confirmed open-at-current no travel, hand-scroll, keyboard reveal, re-click recenter.

  ### Round 2 — deeper simplification (after in-app feedback)

  A second simplify/structure pass driven by user review. Decisions settled:
  - **Keyboard-move animation stays**, but the `ScrollCommand.animated: Bool` is a poor name for what it
    encodes (it conflates *animate?* with *land-at-top vs land-at-nearest-edge*). Replace it with a
    2-case intent `enum ScrollReveal { case jump; case track }`: `.jump` = instant, top-aligned
    (`targetOffset`) for a switch / re-click / filter reflow / launch; `.track` = animated, minimal
    nearest-edge (`revealOffset`) for a Manager keyboard arrow-move. Behavior is identical to today.
  - **`FileCollectionView`'s duplicated scroll-request `.onChange`** (character-identical in `fileList`
    and `gallery` now that both drive one `scrollCommand`) hoists to a single body-level `.onChange`.
    The sibling command-plumbing in `LibrarySurface` (`scrollTrigger` → command) stays its own — the
    two owners produce commands differently (rich `routeScroll` vs simple trigger).
  - **Extract `FileListSurface`** — the windowed list render shared by the Manager list-mode and both
    overlays: `PagedList` of `FileListRow` + the `.id(playlist)` remount + `initialTarget`/`command`
    wiring, centralizing the "remount to reposition" discipline in one place. It takes `ids`,
    `targetIndex`, a remount id, `command`, `role`, `renamingID`, `draftName`, and the row-action
    closures, and forwards them to `FileListRow`. Each owner still computes its own `command`.
    `FileCollectionView` keeps gallery + selection; `LibrarySurface` keeps its 3-column scaffolding.
  - **Folder restructure.** `Shared/` is for views used across *different* features; the file-collection
    machinery (including the generic-looking `PagedList`/`GalleryPagedList`) only ever serves the file
    browser, so it moves into a new `Views/FileCollection/`. Move the cluster —
    `FileCollectionView`, `FileRowView`, `GalleryCell`, `FileListRow`, `FileGalleryCell`,
    `FileListSurface`, `GalleryGrid`, `GalleryPagedList`, `PagedList`, `FileContextMenu`, `FileSelection`
    (and `RenameFileField` if it's file-collection-only) — into it, verifying each file's usages first so
    genuinely cross-feature views stay in `Shared/`. Use `XcodeMV` so the project stays in sync.

  Sub-steps, one at a time, confirmation before each, tests first:
  - [x] **2e — `ScrollReveal` enum.** Replace `ScrollCommand.animated: Bool` with `mode: ScrollReveal`
    (`.jump` / `.track`); update `PagedList.apply`, the `GalleryPagedList` passthrough, `routeScroll`,
    and `LibrarySurface`. `PagedListGeometry` math is untouched; its suite stays green. Verify the
    Manager keyboard-move still animates and switch/re-click still jump-to-top.
    Done: `enum ScrollReveal { case jump; case track }` in `PagedList.swift`; `ScrollCommand.mode`
    replaces the bool; `apply` switches on it (`.track` → animated `revealOffset`, `.jump` → instant
    top-aligned `targetOffset`). `routeScroll`'s closure now yields `.jump`/`.track`; `GalleryPagedList`
    forwards `$0.mode`; the overlay passes `.jump`. Build + navigator clean; 25 geometry/grid tests green
    before and after.
  - [x] **2f — Hoist the duplicated `.onChange`** in `FileCollectionView` to one body-level handler.
    Done: the character-identical `.onChange(of: FileScrollRequest…) { routeScroll… }` is removed from
    both `fileList` and `gallery` and lives once on the body `Group`. Build + navigator clean. Note the
    router now sits on the (non-remounting) body, so a playlist switch fires it *and* the `.id` remount:
    both land the current file top-aligned at the identical offset (`targetOffset`), so the extra `.jump`
    is a visual no-op — to reconfirm at 2i.
  - [x] **2g — Extract `FileListSurface`** and route the Manager list-mode and both overlays through it.
    Done: `Views/Shared/FileListSurface.swift` holds the `PagedList`-of-`FileListRow` render + the
    `.id(playlist.persistentModelID)` remount (computed inside it from the passed playlist, so the
    remount discipline lives in one place). `FileCollectionView.fileList` and `LibrarySurface.fileList`
    are now thin call sites passing `ids`/`playlist`/`role`/`targetIndex`/`command` + the row closures;
    each owner still computes its own `command` (Manager `routeScroll`, overlay `scrollTrigger`).
    `LibrarySurface.fileList` became a `func(playlist:)` (the `fileColumn` unwraps `activePlaylist`).
    Build + navigator clean.
  - [x] **2h — Folder restructure** into `Views/FileCollection/` (last, once the file set is final).
    Done: `Views/FileCollection/` now holds the 11-file cluster — `FileCollectionView`, `FileRowView`,
    `GalleryCell` (from `Views/`) and `FileListRow`, `FileGalleryCell`, `FileListSurface`,
    `GalleryPagedList`, `PagedList`, `FileContextMenu`, `FileSelection`, `GalleryGrid` (from `Shared/`),
    moved via `XcodeMV`. `RenameFileField` stays in `Shared/` (also used by `PlaylistSidebar`), as does
    `LibrarySurface` (the cross-channel overlay surface). Build + navigator clean; 44 pure-logic tests
    across the moved types green.
  - [ ] **2i — Re-verify in-app** (same checks as 2d) after the round-2 changes; navigator clean.
- [x] **Step 3 — Feature docs.** Done: `features/manager-mode.md` gains an "Opening at the current file"
  subsection — every file list (Manager list/gallery, both overlays, launch) opens positioned at the
  highlighted current file with no travel, re-click recenters, filter/Scope reflow re-opens positioned,
  keyboard-move animates, and a filtered-out/never-played current opens at the top. The existing Stopped-state
  line ("current file … is highlighted") already covers the launch highlight, so it stayed as-is.
- [x] **Step 4 — Architecture rationale.** Done: new §6 "File-list windowing" subsection in
  `doc/architecture.md` records why `PagedList` is custom — the three stock approaches that fail the
  open-at-current requirement (`LazyVStack`+`scrollTo` doesn't virtualize the jump; a two-way `scrollPosition`
  binding jitters; `List` eagerly builds O(folder) rows) and how the fixed-height-pages + imperative one-way
  offset + `resident` gate + `.id` remount design meets it. §14's directory tree gains the `FileCollection/`
  group (moved out of Manager/ and Shared/).

## Checklist before done

- Issue navigator clean (no new warnings).
- Follows code conventions; the surfaces share one positioning path, not duplicated per surface.
- Windowing-math test written first, observed red→green.
- Docs describe the code as it is now (no change-narration).
- Remove the temporary row-eval counter in `FileListRow` once `VirtualList` is proven.
