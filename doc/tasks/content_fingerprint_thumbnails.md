# Content-fingerprint thumbnails, cache control, and duplicate search

Captures a cheap content fingerprint for each media file, persists it on the
`PlaylistFile` record, and re-keys the thumbnail cache around it — so the same
file referenced by two playlists shares one generated thumbnail regardless of
folder nesting. The persisted fingerprint then unlocks two follow-on features:
explicit cache management (size / clear / orphan sweep, with the cache moved out
of the OS-purged Caches directory) and a "has duplicates" service filter.

Status: **Stage 1 implemented; Stages 2–6 planned.** Implemented one stage at a
time, in order; each stage is independently shippable and testable.

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

Per the project convention (reusable operations on standard types go in
`Extensions/`), this lands as `Extensions/URL+Fingerprint.swift`:

```swift
import Foundation
import CryptoKit

extension URL {
    /// A cheap, content-derived identity for a media file: stable across rename,
    /// move, and copy, and independent of which folder (or playlist) references
    /// it. Hashes the byte size together with the head and tail windows of the
    /// file — enough to distinguish files without reading gigabytes of video.
    /// `nil` when the file can't be opened.
    nonisolated func contentFingerprint(windowBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var hasher = SHA256()
        // Size first, so two files sharing a head/tail window (padding, shared
        // container header) but differing in length still diverge.
        hasher.update(data: withUnsafeBytes(of: size.littleEndian) { Data($0) })

        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: windowBytes) {
            hasher.update(data: head)
        }
        // Tail window only when the file is larger than one window — otherwise
        // the head already covered the whole file.
        if size > UInt64(windowBytes) {
            try? handle.seek(toOffset: size - UInt64(windowBytes))
            if let tail = try? handle.read(upToCount: windowBytes) {
                hasher.update(data: tail)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

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

```swift
/// The cache filename for a file, and the fingerprint to persist when this path
/// computed one (`nil` when the caller supplied it, or the file is unreadable).
private nonisolated static func cacheFilename(
    fileURL: URL, fingerprint: String?
) -> (name: String, computed: String?)? {
    if let fingerprint {                              // supplied by the record — no read
        return ("\(fingerprint).heic", nil)
    }
    guard let computed = fileURL.contentFingerprint() else { return nil }
    return ("\(computed).heic", computed)             // first display — compute + report
}
```

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

- **Cache size** — sum of all files in the dedicated cache directory.
- **Clear all** — remove the directory's contents.
- **Clear orphans** — remove only `.heic` files whose key is not referenced by any
  live record. A single query for all `PlaylistFile.fingerprint` values 
  and intersection against existing `.heic` file names.

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
sort fits), the tool overrides the Manager center's *memoized sequence*
transiently. `managerFileIDs` (`AppState+Playback.swift:20`) is derived through
`memoizedSequence` from `displaySequence(of:)`; the tool adds a runtime-only
override holding a precomputed `[PersistentIdentifier]` — the playlist's files
whose fingerprint recurs (count ≥ 2), grouped and ordered by fingerprint so
duplicates sit adjacent. While the override is set, `managerFileIDs` returns it
instead of the store sequence; clearing it (on dismiss, playlist switch, or a
filter edit) falls straight back to `displaySequence`. No new column, no
`FilterState` case, no persistence — a one-shot in-memory list computed from a
`(id, fingerprint)` fetch.

---

## Implementation plan

Each stage is implemented on its own, test-first, and confirmed with the user
before the next begins. Stage 1 is the core; 2–4 are the follow-ons the persisted
fingerprint unlocks and can be scheduled independently; 5–6 are the doc and
housekeeping wrap-up. Each code stage updates the doc-comments of the files it
touches as part of the change (per the writing rules) — Stage 5 is the separate
pass over the standalone primary docs, once the shape is final.

### Stage 1 — Fingerprint the thumbnail cache + persist on the record (schema V7)

The fingerprint, the cache re-key, and its persistence land together: the
thumbnail produce path needs the fingerprint to key the cache, computes it there,
and reports it back to persist. (Computing it without keying on it, or keying
without persisting, would be half a change.)

1. Add `Extensions/URL+Fingerprint.swift` (`contentFingerprint(windowBytes:)`).
2. Add `fingerprint: String?` to `MediaMetadata`, to `PlaylistFile`, and to
   `PlaylistFile.merge(_:)`. Leave `hasCompleteMetadata(for:)` and
   `MediaMetadataService` untouched (the list path never fills it).
3. Thread `file.fingerprint` from `thumbnail(for:in:maxPixelSize:)` down through
   `produceImage` → `produceData` to the filename computation. Replace
   `cacheKeyComponents` with the `cacheFilename` helper above (supplied fp → name,
   no read; absent → compute, name, and report for persistence; unreadable → no
   name, no thumbnail); the fingerprint *is* the name, so delete the now-unused
   `digest` helper and drop the modification-date stamp. Have `produceData` fold
   the computed fingerprint into the `MediaMetadata` it returns, so the existing
   `GalleryCell` merge persists it. Update the `cacheKey` test seam accordingly.
4. Schema V7 (`doc/versioning.md` recipe): freeze the current shape into
   `SchemaV6` as pinned `@Model` copies of the **Playlist ↔ PlaylistFile ↔ Tag**
   relationship component (pin the whole component together;
   AppStateModel / GlobalSettings / SchemaMarker carry no reference into it and
   keep the live types); create `SchemaV7` referencing the live types; make the
   live `PlaylistFile` change; register V7 + a `.lightweight` V6→V7 stage in
   `AppMigrationPlan`; point `ShuTaPlaApp` at `SchemaV7`.

**Tests (test-first):**
- Fingerprint is stable across a rename (same bytes → same fingerprint) and
  across the same content at two different relative paths.
- Content change (or a size change with an identical window) yields a different
  fingerprint; the size-first update guards the shared-window case.
- Unreadable file → `contentFingerprint` is `nil`; the produce path yields no
  thumbnail and touches no cache entry.
- The same bytes at two different relative paths produce the **same** cache
  filename → a second load is a disk hit (the cross-folder sharing this targets).
- A supplied (persisted) fingerprint yields the same filename as the computed one
  and performs no file read; `merge` fills a `nil` fingerprint and leaves a set
  one untouched.
- Migration test: a V6 store's rows survive V6→V7 and open with
  `fingerprint == nil`, repopulating on next display (per the versioning recipe).

### Stage 2 — Move cache to app folder + management UI

1. Point `ThumbnailService`'s default cache directory at Application Support.
2. Add cache-size, clear-all, and clear-orphans operations (no pre-calculation of orphaned size because it is slow, after running orphan search and cleanup report to user number of removed files and total size).
3. Surface them in `SettingsView` (a new "Thumbnail cache" section).

**Tests (test-first):**
- Size sums only `.heic` files.
- Clear-all empties the directory.
- Clear-orphans removes exactly the files whose key no live fingerprint produces
  and keeps the referenced ones (seed a fixture cache dir + a set of records).

### Stage 3 — "Find duplicates" tool 

A nearly-free extra over the persisted fingerprint, invoked from
`PlaylistSettingsView` — not a service filter. Compute the playlist's files whose
fingerprint recurs (count ≥ 2) from a `(id, fingerprint)` fetch, ordered by
fingerprint so duplicates are adjacent, and hold the result as a runtime-only
override of `managerFileIDs`; clear it on dismiss / playlist switch / filter edit.
No `FilterState` case, no persistence, no change to `ModelContext+Sequence.swift`.
Show a disclaimer that it compares only thumbnailed files. Test the grouping
(which fingerprints recur), the fingerprint-ordered result, and that setting and
clearing the override swaps the Manager sequence and restores it; the coverage
limit is by design, not a gap to close.

### Stage 5 — Update the primary docs

Once the shape is final, revise the standalone primary docs to describe the code
as it then stands (per the writing rules — no change-narration):

- `doc/architecture.md` — the thumbnail cache's fingerprint keying and its
  Application Support location.
- `doc/features.md` + the relevant `doc/features/` chapter — the cache-management
  settings and the find-duplicates tool, if those stages shipped.

(The per-file doc-comments — e.g. `ThumbnailService.swift`'s header, which today
still says "cached … on disk (Caches directory)" and keyed "by relative path +
modification date" — are corrected within the code stages that change them, not
here.)

### Stage 6 — Clean up stale on-disk thumbnails and container debris

One-time housekeeping on the two app containers, once Stage 2 has moved the cache
to Application Support (so the old location is truly dead):

- **Old thumbnail caches** under the Caches directory of both containers:
  - `~/Library/Containers/com.aytigra.ShuTaPla/Data/Library/Caches/com.aytigra.ShuTaPla/Thumbnails`
  - `~/Library/Containers/com.aytigra.ShuTaPla.debug/Data/Library/Caches/com.aytigra.ShuTaPla.debug/Thumbnails`
- **Coverage/profiling temp debris** — the hundreds of
  `UUID-PID-timestamp` folders directly under each container's `Data/`, holding
  `.profraw` (LLVM coverage) files or empty. Accumulated one-or-more per test/app
  run and never reaped; not app data. Safe to delete wholesale.

This is a manual/one-shot cleanup, not app code — the store and (post-move) the
live thumbnails are untouched. Left last so it runs against the final layout.
