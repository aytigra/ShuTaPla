# Task — cut the thumbnail miss-path cost

Two ideas for making a cold scroll over a large playlist cheaper were on the table. The first was
tried and reverted; the second is the active work.

## Attempt 1 — HEIC blob in-memory cache (reverted, a bust)

The idea: hold **encoded HEIC blobs** in `ThumbnailService`'s in-memory cache (`NSCache<NSString, NSData>`)
and decode on demand at the cache hit, instead of caching decoded `NSImage` bitmaps — an ~22× smaller
footprint per entry (~25–29 KB blob vs ~563 KB decoded) so a whole library (~38 MB of blobs) stays
resident and scrolling never falls to the disk/bookmark path.

**It made memory worse, not better, and gave no perf win.** Measured in the Xcode Debug navigator:
the decoded-`NSImage` scheme caps ~160 MB and instantly recovers to ~140 MB; the blob scheme rose to
~215 MB and spiked to ~270 MB under back-and-forth scrolling. Two causes:

- **The whole library's blobs stay resident** (~38 MB, under any sane budget → never evicts), an
  always-on floor the decoded cache never had.
- **Allocation churn.** The blob scheme decodes a fresh ~563 KB bitmap on *every* warm hit, where the
  old scheme returned the *same* shared cached `NSImage` (zero allocation on re-appearance). The warm
  path lost its former zero-decode advantage.

Perf was flat either way (the cold placeholder-load scroll felt, if anything, slightly smoother than
the warm one — plausibly because thumbnail reads are off-main and land lazily as a landed page settles).

**Reverted.** `ThumbnailService` is back to `NSCache<NSString, NSImage>`, 128 MB budget, `produceImage`
decoding off-main. Shrinking the decoded budget to trim memory is a non-starter: the most crowded
viewport on a 14" screen is ~212 items, so the cache must comfortably exceed that.

Facts worth keeping from the measurement (still true): decode via `NSBitmapImageRep(data:).cgImage` is
~0.3 ms/thumbnail (p99 ~0.38 ms); disk read is also ~0.3 ms. So the miss path's cost is **not** decode
or I/O.

## Attempt 2 — hoist security-scoped bookmark resolution to the surface (active)

If decode and read are each ~0.3 ms, the remaining per-miss cost is that `produceData`
(and `MediaMetadataService.extract`) call `BookmarkService.withResolvedFile` **per file**, each doing a
`resolve(bookmark)` (`URL(resolvingBookmarkData:)`) plus a `start/stopAccessingSecurityScopedResource`
round-trip. A cold pass over a large playlist pays this once per file — potentially twice for a gallery
cell that also needs metadata.

**The plan:** open one reference-counted scoped-access session per browsed folder for the surface's
lifetime, and feed the already-resolved folder URL into the workers so they append the relative path
instead of resolving per file.

- **Owner + lifetime:** the file surface (`FileCollectionView` for the Manager; the overlay's file
  list too) opens the session via `BookmarkService.startAccess(to:)` in a `.task(id: playlist.persistentModelID)`
  and releases it via `stopAccess` on cancellation (playlist switch / disappear). `startAccess` is
  per-URL refcounted, so gallery + list + overlay + an active playback session on the same folder all
  share one OS grant, released when the last closes. (Do **not** reuse `ScopedFolderAccess.begin/end`
  — its id-keyed map is not re-entrant across owners.)
- **Data flow:** publish the resolved folder `URL` down to the cells/rows (a new `EnvironmentValue`
  set once on the surface). `GalleryCell`, the list row, and the overlay row read it and pass it into
  `thumbnail(...)` / `metadata(...)`.
- **The workers:** `thumbnail`/`metadata` gain an optional pre-resolved `folderURL`. When present, the
  `@concurrent` worker appends `relativePath` and skips `withResolvedFile` entirely (still does
  `fileExists` + size/mtime + read/decode). When absent (tests, non-surface callers), the current
  per-file path is unchanged — so every existing test keeps passing.

### Confirmed design points

1. **Both services, both surfaces.** Thumbnails (gallery only) *and* metadata (gallery, Manager list,
   overlay list) resolve per file. The overlay list uses only the metadata service. So the pre-resolved
   URL must reach the metadata call on every file surface, not just the gallery.
2. **Main-mount / off-main-read is correct, not a hazard.** `startAccessingSecurityScopedResource()`
   grants access **process-wide while active** — not per-thread. Mounting once on the main actor and
   reading off-main is sound: only the `Sendable` folder `URL` crosses to the `@concurrent` worker; the
   per-file open stays off-main. What leaves the worker is the per-file `resolve` + `start/stop`; what
   moves on-main is one resolve + one start per surface open (negligible).

### Verify first — is per-file resolve actually a meaningful cost?

The premise is **unmeasured**. Decode (~0.3 ms) and read (~0.3 ms) were measured; `resolve` +
`startAccessingSecurityScopedResource` never was — `withResolvedFile` bundles them with the read in one
closure. And the reverted attempt's cold≈warm feel is mild evidence *against* per-file resolve being a
bottleneck.

**Step 0 — measured (debug build, cold pass over the 1412-file playlist, n≈1400):** a temporary
timing probe in `BookmarkService.withScopedAccess` (async form) split the per-file cost into
`resolve` / `startAccess` / `body`, logged via `Logger.notice` and read back with `log show`.

| interval | avg/call | |
|---|---|---|
| resolve (`URL(resolvingBookmarkData:)`) | **~1370 µs** | the same folder bookmark, re-resolved per file |
| startAccess | ~10 µs | negligible |
| body (read + decode) | ~1000 µs | wall time; ~600 µs is real CPU, rest is async slack |
| **resolve + start** | **~1384 µs = 58% of total** | |

Per-file resolution is the **largest** miss-path cost — bigger than the read+decode it wraps — and it
is pure redundancy (one folder bookmark resolved ~1400×). Probe validated against false positives:
`resolve` is synchronous so its timing carries no async-suspension slack (unlike `body`, whose wall
time is inflated), and warm memory hits never reach this path, so every counted call is a real cold
resolve. Caveat: worker-thread parallelism means wall-clock scroll gain is < 58% (the ~1.9 s of resolve
thread-time removed across the pass is spread over several `@concurrent` workers); absolute µs are
debug-build figures, but the ratio is build-independent.

**Decision: build the hoist.** Remove the timing probe as the first implementation step.

### Implementation

**Step 1 — probe removed.** `BookmarkService` is back to clean; no `os`/`Synchronization` imports, no
probe.

**Step 2 — the service seam (done).** `BookmarkService.withResolvedFile` gained an optional
pre-resolved `folder: URL?` (default `nil`): supplied → append `relativePath` + `fileExists` + run
`body`, skipping the per-file `resolve` + start/stop; `nil` → today's per-file resolve, unchanged. The
workers thread it through: `ThumbnailService.thumbnail`/`thumbnailData` → `produceImage` →
`produceData`, and `MediaMetadataService.metadata` → `extract`, each gaining a `folderURL: URL? = nil`.
Confirmation/refutation test in both service suites (`preResolvedFolderBypassesPerFileBookmarkResolution`):
with a deliberately *unresolvable* bookmark, the read succeeds when `folderURL` is supplied and fails
when it's `nil` — proving the folder path bypasses resolution and the fallback still resolves per file.
All existing service tests pass on the preserved `nil` path.

**Step 3 — the surface session + plumbing (done).**

- **Owner + lifetime.** Both file surfaces open a session in a `.task(id: playlist.persistentModelID)`:
  `FileCollectionView` (Manager gallery + list) and `LibrarySurface` (overlay lists). The session is a
  new pass-through on `ScopedFolderAccess` — `beginBrowsing(_:) -> URL?` / `endBrowsing(_:)` — that
  forwards straight to `BookmarkService.startAccess`/`stopAccess` (per-URL reference-counted,
  re-entrant across owners), *not* the id-keyed playback map. So a browse surface, a second overlay,
  and a live playback session on one folder each hold an independent ref, and the OS grant drops only
  when the last releases. The `.task` parks (`while !Task.isCancelled { try? await Task.sleep }`) to
  hold the grant for the surface's lifetime; a playlist switch (new id) or the surface leaving cancels
  it, and its `defer` calls `endBrowsing`. A stale/unresolvable bookmark → `beginBrowsing` returns
  `nil`, no grant taken, no park — the cells fall back to per-file resolve (unchanged).
- **Publish, id-paired.** The resolved URL reaches the leaf cells through a new
  `EnvironmentValue browsingFolderURL: URL?` set on the surface. The published value is **paired to the
  shown playlist**: the surface stores `(playlistID, url)` and publishes the url only while
  `playlistID == playlist.persistentModelID`, else `nil`. This closes the switch race — the `@State`
  set inside the async task lags the first render, so on a switch the old url is never handed to the
  new playlist's cells (they see `nil` → safe per-file fallback until the new session's url is
  published). `GalleryCell` reads it for both its `thumbnail(...)` and `metadata(...)` calls;
  `FileRowView` (list + overlay) reads it for its `metadata(...)` call. The leaf wrappers
  (`FileGalleryCell`, `FileListRow`) need no change — the environment propagates.
- **Not optimized: the first screenful right after a switch.** Cells key their `.task` on the file id,
  not `browsingFolderURL`, so cells that mounted during the brief `nil` window use the per-file
  fallback and don't upgrade when the url arrives. This is deliberate: the target win is the *cold
  scroll* over a large playlist (every later screenful is fast), and skipping a re-fire keeps each cell
  a single produce. Correct either way; only the first ~screenful forgoes the speedup.
- **Tests.** `ScopedFolderAccessTests` gains browse-session coverage: `beginBrowsing` holds one ref and
  resolves the url; a browse ref and a playback `begin` on one folder share the grant (refCount 2) and
  each is balanced independently; an unresolvable bookmark yields no session and no ref.
