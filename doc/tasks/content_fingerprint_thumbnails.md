# Content-fingerprint thumbnails, cache control, and duplicate search

Captures a cheap content fingerprint for each media file, persists it on the
`PlaylistFile` record, and re-keys the thumbnail cache around it — so the same
file referenced by two playlists shares one generated thumbnail regardless of
folder nesting. The persisted fingerprint then unlocks two follow-on features:
explicit cache management (size / clear / orphan sweep, with the cache moved out
of the OS-purged Caches directory) and a "has duplicates" service filter.

Status: **Stages 1–6, 8 implemented; Stage 7 (modification-date invalidation
gate) planned.** Implemented one stage at a time; each stage is independently
shippable and testable.

## Problem

`ThumbnailService.cacheKeyComponents` (`ThumbnailService.swift:148`) keys its
on-disk cache by relative path:

```swift
digest("\(relativePath)|\(stamp)|\(maxPixelSize)")   // stamp = modification date
```

This already shares a generated thumbnail between two playlists **when both are
rooted at the same folder** — the relative path and modification date coincide,
so the second playlist gets a disk hit. It breaks down the moment the shared
folder sits at a different depth in the two playlists (root of one, subfolder of
another): the relative paths differ (`clip.mp4` vs `sub/clip.mp4`), the keys
diverge, and the frame is extracted and encoded twice.

Two secondary consequences of the path-based key:

- **Renames orphan thumbnails.** Renaming a file changes its relative path, so a
  fresh thumbnail is generated under the new key and the old `.heic` is stranded
  on disk. The cache has no eviction (the only `removeItem` in
  `produceData` drops a corrupt cache file before regenerating), so stranded
  entries accumulate until macOS purges the Caches directory under disk pressure.
- **Cross-folder key collision.** The disk key omits the folder bookmark, so two
  *different* files in two folders that happen to share a relative path, size,
  and modification date hash to the same entry and can cross-paint. (The
  in-memory `NSCache` key — `memoryKey`, `ThumbnailService.swift:115` — avoids
  this by including `playlist.id`; the disk key does not.)

A content fingerprint addresses all three: it is independent of which folder
references the file, stable across rename/move, and derived from the bytes so a
collision requires genuinely matching content. Persisting it on the record then
lets the orphan sweep and duplicate search read identity from the model instead
of re-opening files.

## Fingerprint function

A full hash of a multi-GB video is too expensive to run on a scan. The standard
compromise is a windowed fingerprint: the byte size plus a SHA-256 over the head
and tail windows of the file. Two reads of a fixed window, regardless of file
size, and collision-resistant enough for "is this the same media file."

The fingerprint changes whenever the content changes, so it carries its own
invalidation — the modification-date stamp can be dropped from the cache key.

## How the fingerprint reaches the model

The fingerprint exists to key the thumbnail cache, so it is **the thumbnail
service's own concern** — computed and consumed in `ThumbnailService`, not by a
separate metadata-extraction path. The thumbnail produce path already resolves
and opens the file and now *needs* the fingerprint to key the cache, so it
computes it there and reports it back to persist on the record through the same
channel every other file fact already rides.

`ThumbnailService.produceData` returns `(data: Data?, metadata: MediaMetadata)`;
`MediaMetadata` (`MediaMetadata.swift`) is "the bundle of file facts read once
off the main actor and cached on `PlaylistFile`" (`duration / width / height /
fileSizeBytes`), folded onto the model through `PlaylistFile.merge(_:)`, which
fills only fields still `nil`. The fingerprint is exactly such a fact, so it
joins the bundle:

- Add `fingerprint: String?` to `MediaMetadata`, to `PlaylistFile`, and to
  `merge(_:)` (fill when `nil`).
- **Do not** add it to `MediaMetadataService` (the list-mode extractor) or to
  `hasCompleteMetadata(for:)` — the list path leaves `fingerprint == nil`, just as
  it leaves `duration == nil` for an image. `hasCompleteMetadata` gates the list
  extractor, and folding the fingerprint into it would force an endless
  re-extraction there (the list path never fills it).
- Only the thumbnail producer fills it. `GalleryCell` already calls
  `file.merge(result.metadata)`, so the value persists with no view-layer change.

The consequence — that a file never shown in the gallery (an audio file, or one
never scrolled to) carries no fingerprint — is exactly right for the thumbnail
cache and the orphan sweep (an un-thumbnailed file has no cache entry to key or
protect). It is the one open question for duplicate search; see that section.

**Persisting the fingerprint is a SwiftData stored-shape change** — a new
optional column — so it needs a schema version bump and a lightweight migration
stage (see `doc/versioning.md`). The value is recomputable from the file bytes
and repopulates on the next display, so the stage never migrates it as data;
existing rows simply start with `fingerprint == nil`.

## Re-keying the thumbnail cache

`cacheKeyComponents` runs `nonisolated` inside `produceData`'s resolved-bookmark,
scoped-access closure (`ThumbnailService.swift:148`), so the `URL` is in hand.
But it receives only Sendable values — never the `PlaylistFile` model — so a
*persisted* fingerprint is **threaded down from the main-actor entry point**,
which does hold the model:

- `thumbnail(for:in:maxPixelSize:)` reads `file.fingerprint` and passes it
  through `produceImage` → `produceData` → the filename computation.
- The fingerprint is already a filesystem-safe SHA-256 hex string, so it *is* the
  cache filename: `"\(fingerprint).heic"`. No hashing — the old `digest(...)`
  existed only to make the arbitrary `relativePath` a legal name, so it (and its
  only caller, the disk key) goes away. Hit/miss is a plain file check on that
  name. `maxPixelSize` is not in the name: every caller passes the one
  `galleryThumbnailPixelSize` (multiple thumbnail sizes was never a feature), so
  it stays purely a render input to `renderThumbnail`, not part of cache identity.
- When a fingerprint is supplied, the name is formed with **no file read**.
- When it is `nil` (first display, before the record is populated; or the
  model-less seams `thumbnailData` / the `cacheKey` test entry point), the closure
  computes `fileURL.contentFingerprint()` itself and **reports it back** in the
  returned `MediaMetadata`, so `GalleryCell`'s existing `file.merge(result.metadata)`
  persists it for later sessions. (This holds on a disk-cache *hit* too: the
  fingerprint had to be computed to form the name that found the `.heic`, so it is
  reported regardless of hit or render.)
- When the file can't be fingerprinted, it can't be thumbnailed either — there is
  no cache entry to name. **No fallback:** the produce path returns no thumbnail
  (the cell shows its placeholder), so an unreadable file touches the cache not at
  all and can't collide with anything.


Re-keying needs no separate migration: existing `.heic` files will be cleaned out 
manually and new durable thumbnails will be generated in dedicated app folder.

### Cost trade-off

The disk-cache key is computed only on an **in-memory miss** — `cachedThumbnail`
serves warm scroll hits from the `NSCache` with no disk I/O and never computes
this key. So the added cost is one 128 KB read per cold load *only until the
fingerprint is persisted* — once the record carries it, the main-actor entry
supplies it and the read is skipped. A cold load already pays a disk read for the
`.heic` body on a hit and a full decode on a miss, so even the first read is
modest against either.

## Cache management

Two problems the fingerprint enables solving together:

- **The disk cache never shrinks on its own.** Re-keying and renames strand old
  `.heic` files; nothing evicts them.
- **The cache lives in the OS Caches directory** (`ThumbnailService.init`, via
  `.cachesDirectory`), which macOS purges under disk pressure with no regard for
  what's still referenced — throwing away thumbnails the user is actively using.

Move the cache into the app's Application Support folder so it is under our
control, and add an explicit management UI:

The cache folder is ours and single-writer, so it legitimately holds *only*
live-referenced `.heic` thumbnails — the three operations agree on that invariant:

- **Cache size** — the whole directory's footprint.
- **Clear all** — remove the directory's entire contents.
- **Clear orphans** — reduce the directory to that legitimate set: remove every
  `.heic` whose fingerprint no live record references, plus any stray non-`.heic`
  file. Live fingerprints come from a single query for all `PlaylistFile.fingerprint`
  values; everything else in the folder is swept.

A background task can run the orphan sweep periodically; storing the fingerprint
on the record is what lets it enumerate live keys without opening any file.

## Duplicate search

Not an important feature in its own right — a nearly-free extra the persisted
fingerprint hands us, and deliberately **not a service filter**. It doesn't
combine with the tag/triage filters, doesn't appear in the filter bar, and
persists nothing on the playlist. It's a **buried tool** invoked from
`PlaylistSettingsView`: run it, the Manager center shows the playlist's duplicate
files grouped together, and dismissing it (or any normal filter interaction)
returns to the ordinary view.

Because only the thumbnail producer fills the fingerprint, the tool compares only
files that have been thumbnailed — a file never shown in the gallery has no
fingerprint, and an audio playlist (list-only) has none at all. That is fine and
not worth closing with a display-independent fingerprinting pass; a short UI
disclaimer ("finds duplicates among thumbnailed files") sets the expectation.

**It leaves the store-side predicates alone.** Rather than add an arm to the
effective-filter machinery (`ModelContext+Sequence.swift`, whose every filter is
one `#Predicate` sorted by `sortOrder` — neither a grouping pass nor a fingerprint
sort fits), the tool is a transient **mode** of the Manager center, not a separate
surface: the center list *is* the duplicate view, fed a different sequence, so the
existing selection model, list/gallery toggle, keyboard 2-D nav, and delete path
are reused unchanged.

`managerFileIDs` (`AppState+Playback.swift:20`) is derived through
`memoizedSequence` from `displaySequence(of:)`. The tool adds a runtime-only flag
`duplicateSearchActive`; while it is set, the memoized closure derives
`duplicateSequence(of:)` — the playlist's files whose fingerprint recurs
(count ≥ 2), grouped and ordered by fingerprint so duplicates sit adjacent —
instead of `displaySequence`. Because it routes through the *same* memoization, it
is **a live derivation, not a frozen snapshot**: it recomputes on every
`sequenceVersion` bump, so deleting a duplicate is the tool working as intended —
the bump re-derives the grouping, the trashed file drops out, and any fingerprint
now down to a single copy stops recurring so its group dissolves on its own.

Correctness details:

- **Toggling the flag bumps `sequenceVersion`** (it is a membership change of the
  center list), so the shared `managerFileIDsMemo` slot never serves a stale
  other-mode result.
- **Clearing is explicit and narrow.** The center `noticeBar` shows a "Showing
  duplicates · Done" banner while active, whose Done button leaves the mode; the
  filter-bar edits and playlist-switch paths also set `duplicateSearchActive =
  false` (any normal filter interaction returns to the ordinary view).
  `deleteFiles` does **not** touch the flag — it only bumps
  the version — so a delete recomputes *within* duplicate mode instead of exiting
  it. Delete and filter-edit both bump the version; only the filter-edit path
  clears the flag, so they stay distinguishable.
- **Selection is reset on entering and leaving the mode**, so a selection made
  against one sequence doesn't linger into the other.

No new column, no `FilterState` case, no persistence — a flag plus a
`(id, fingerprint)` fetch grouped in Swift, invoked inside the memoized closure.

---

## Fingerprint invalidation & review fixes

Once a fingerprint is persisted, nothing re-validates it: the produce path trusts
the record's fingerprint verbatim and `merge` only fills a `nil` field, so an
in-place content change (in practice **remove-sound**, which rewrites the file)
would serve the old identity forever — quietly breaking the "a content change
yields a new fingerprint" invariant this design rests on. This stage restores a
cheap, generic invalidation, plus three smaller fixes surfaced in review.

1. **Filesize-gated invalidation → full re-derivation.** Thread the record's cached
   `fileSizeBytes` into the produce path (`thumbnail(for:in:maxPixelSize:)` →
   `produceImage` → `produceData`). `produceData` already reads the on-disk size;
   when a fingerprint is *supplied* but the on-disk size differs from the record's
   cached size, the bytes changed (in practice remove-sound, or a different file at
   the same path), so every cached fact is suspect. Treat it as a hard
   invalidation: discard the supplied fingerprint, recompute from the current bytes,
   and **re-render rather than serve a `.heic`** — so `duration`/`width`/`height` are
   re-derived from a fresh decode, not left over from the old file. Size-gated, so
   the hot path pays nothing extra and a same-size hit still skips the read and
   re-renders nothing. Generic: any in-place edit that changes the file size —
   remove-sound included — is caught on the next produce, with **no** special-case in
   the strip path. It self-heals on the next in-memory miss (a thumbnail keyed by
   relative path isn't re-validated while resident; acceptable — no synchronous key
   can detect a byte change without statting on the scroll path, which is exactly
   what the move off the modification-date key dropped).
2. **Coalesce-non-nil merge.** For the re-derivation to persist, `PlaylistFile.merge`
   overwrites each field whenever the incoming metadata carries a non-`nil` value and
   leaves it untouched when the incoming value is `nil` (`if let v = metadata.duration
   { duration = v }`, and so for every field) — one uniform rule, not a per-field
   split. A freshly-read value always wins; a field a producer didn't determine never
   erases what's cached. This is safe because `nil` in the bundle means "this producer
   didn't read this field," not "the value is nil": a disk-cache *hit* reports
   `duration`/`width`/`height` as `nil` (no decode ran) and so leaves a prior decode
   intact, while a fresh render (first display or a size-mismatch re-derivation)
   reports all of them and fully refreshes the record. It replaces the former
   fill-only rule, which could let neither a recompute overwrite a stale
   fingerprint/size nor a changed file's stale duration/dimensions.
3. **No fingerprint for a thumbnail-less file (review #3).** In `produceData`, set
   `rendered.metadata.fingerprint` only *after* the `guard let data = rendered.data`,
   so a file that opens but fails to render (corrupt, 0-byte) never persists a
   fingerprint. Makes the Find Duplicates disclaimer ("compares only thumbnailed
   files") true and stops every 0-byte file collapsing into one duplicate group.
4. **Flush before Find Duplicates (review #5).** `findDuplicates(in:)` calls
   `persistAndRefresh()` before `setDuplicateSearch(true)`, so fingerprints merged
   while scrolling are saved before `duplicateSequence`'s `includePendingChanges:
   false` fetch runs (otherwise a just-viewed file's fingerprint is invisible to
   the grouping).
5. **Cache-size notice (review #2).** In `SettingsView`'s "Thumbnail cache"
   section, show a warning line when `cacheSize` exceeds 1 GB. The disk cache has
   no automatic eviction by design; the notice nudges a manual clear.

Considered and declined: invalidating the in-memory entry on strip (the frame is
unchanged — nothing to gain); clearing the in-memory cache on clear / clear-orphans
(those buttons free disk space, not individual thumbnails); pre-clearing the
fingerprint in the strip path (the filesize check subsumes it); a two-tier merge
(authoritative for fingerprint/size, fill-only for the rest) — the uniform
coalesce-non-nil rule is simpler and, on a size-mismatch re-render, refreshes the
stale duration/dimensions too. A same-size in-place edit is not detected — an
accepted rarity, consistent with the deliberate move off the modification-date key.

**Tests (test-first):**
- Supplied fingerprint + unchanged on-disk size → no read, supplied name reused,
  nothing reported to persist (the existing disk-hit test still holds).
- Supplied fingerprint + changed on-disk size → full re-derivation: the new
  fingerprint names the entry and is reported back; a fresh decode reports the new
  duration/dimensions; the disk `.heic` under the new name is re-rendered, not
  served; `merge` overwrites the stale fingerprint, size, and dimensions.
- `merge` coalesces non-`nil`: an incoming non-`nil` value overwrites, an incoming
  `nil` leaves the field untouched (update the existing merge and list-healing tests
  to the coalesce semantics).
- A file that opens but fails to render persists no fingerprint (image `nil`,
  `metadata.fingerprint == nil`); two 0-byte files are not grouped as duplicates.
- `findDuplicates(in:)` saves first: a fingerprint merged but unsaved is visible to
  the mode's fetch.
- Cache-size notice appears above the 1 GB threshold and not below (logic-level if
  the view seam allows; otherwise a manual check).

---

## Stage 7 — Modification-date invalidation gate

The filesize gate (Stage 4, section 1) misses an in-place edit that preserves the
byte size **and** both 64 KB fingerprint windows but changes the middle — the
windowed fingerprint can't see it, and size alone doesn't move. `mtime` is the
cheap universal "look again" signal: any in-place edit bumps it. Split the two
roles the record already conflates:

- **Staleness trigger** ("re-examine this file?"): the on-disk `fileSize` **or**
  `contentModificationDate` differs from the record's cached values.
- **Identity** ("same content?"): the fingerprint (size ‖ head ‖ tail) — unchanged.

Design:

- New stored `lastModified: Date?` on `PlaylistFile`, carried in `MediaMetadata`
  and set by the **thumbnail producer only**, alongside `fingerprint` — a file
  first seen in list mode has neither until it is thumbnailed, and the gate needs a
  prior fingerprint to invalidate, so the two always travel together. `merge`
  coalesces it like every other field. The thumbnail producer already stats the
  file for its size, so reading the mtime is free.
- **SwiftData stored-shape change** → new `SchemaVN` + pinned prior + lightweight
  stage (see `doc/versioning.md`; same shape as the fingerprint column in Stage 1).
  Recomputable, never migrated as data — existing rows start `lastModified == nil`.
- Thread the record's cached `lastModified` into the produce path beside
  `recordFileSize`. In `produceData`, the **gate fires** when a fingerprint is
  supplied and either the on-disk size or the on-disk mtime differs from the
  record's. When it fires, **recompute the fingerprint** from current bytes:
  - If it **equals** the supplied one (a benign mtime bump — touch, copy,
    re-download of identical bytes), the content is the same: serve the cached
    `.heic`, and report `fingerprint` + `fileSizeBytes` + `lastModified` so the
    record's stale mtime refreshes and the gate stops re-firing.
    `duration`/`width`/`height` stay `nil` (preserved).
  - If it **differs**, the content changed: force a fresh render (skip the disk
    hit) and report the new fingerprint plus fresh `duration`/`width`/`height` +
    size + mtime — a full re-derivation.
- This **generalizes and replaces Stage 4's size-only rule.** "Size mismatch →
  always re-render" becomes "gate fires → recompute → re-render only if the
  fingerprint moved." A size change still forces a re-render (size is hashed into
  the fingerprint, so it always moves it), so Stage 4's behavior is preserved as a
  special case, while benign mtime bumps no longer waste a decode.
- Unchanged: the fast path (neither size nor mtime moved → supplied fingerprint,
  disk hit, no read); the in-memory `NSCache` self-healing limitation (a resident
  thumbnail isn't re-validated while it stays in memory).

Tests (test-first):
- Same size, changed mtime, **unchanged** bytes → fingerprint recomputed and equal
  → cached `.heic` served (no re-render), record's `lastModified` refreshed,
  `duration` preserved.
- Same size, changed mtime, **changed** middle bytes → fingerprint differs → fresh
  render, new fingerprint + refreshed duration/dimensions reported.
- Changed size → still a full re-derivation (the Stage 4 test continues to hold
  under the generalized rule).
- Neither size nor mtime changed → fast path, no read, supplied name reused.
- Migration: existing rows load with `lastModified == nil` and populate on next
  display.

## Stage 8 — Cache-pressure banner

The Stage 4 cache-size notice lives in Settings, which the user may never open.
Surface it where it's seen, driven off the existing playlist scan — no new
cache-scan cadence and no running byte counter.

- **Flag from the playlist scan.** `AppState.update(_:)` (the background re-scan
  that fires on every playlist select/re-click, already off the main actor)
  `await`s `ThumbnailService.defaultCacheSize()` — the off-main folder-size sum —
  and publishes an `@AppStorage("thumbnailCacheOverLimit")` bool via
  `ThumbnailService.publishCachePressure(bytes:)` (`bytes >
  AppConstants.thumbnailCacheWarningBytes`). Scans are infrequent and already
  off-main, so this piggybacks with no new cadence; `@AppStorage` updates SwiftUI
  reactively. **Settings republishes the flag after a clear/orphan sweep** (through
  the same helper), so a sweep that drops the cache back under the threshold clears
  the banner promptly rather than leaving it stale until the next scan.
- **Banner in the notice strip.** `PlaylistCenterView.noticeBar` gains an orange
  row shown when the flag is set — copy **"App cache > 1Gb!"** — presented as a
  `SettingsLink` so a click opens the Settings scene (nothing else in the app opens
  Settings today). It sits alongside the existing duplicate / service-filter notices.
- **Settings inline (supersedes Stage 4 item 5's Label).** Drop the separate
  caution `Label`; instead color the existing "Cache size" value orange when its
  freshly-read size is over the limit. A small pure
  `SettingsView.cacheOverLimit(bytes:) -> Bool` keeps the threshold in one place and
  stays unit-testable; the Stage 4 `cacheSizeWarning(bytes:) -> String?` and its
  test are replaced by it.

Tests (test-first):
- `cacheOverLimit(bytes:)` is false at/below the threshold and while loading
  (`nil`), true above.
- `update(_:)` sets the `@AppStorage` flag from the scanned size (logic-level via a
  seam if practical; otherwise a manual check of the banner).
