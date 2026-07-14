# Task — Metadata-path staleness & on-disk-change invalidation

Cached file metadata doesn't react when a file changes on disk unless it happens to pass through the
thumbnail generator. This closes that gap generally, so a file resized/optimized elsewhere refreshes its
cached facts everywhere they're shown. It benefits every file type.

Status: **design settled; not started.** Test-first, one sub-step at a time after confirmation.

## The gap

Cached file facts (`duration`, `width`, `height`, `fileSizeBytes`, `lastModified`, `fingerprint`) live on
`PlaylistFile`, filled on first display and reused forever after. Only **one** of the paths that read them
notices a file changed on disk:

- **Thumbnail path (has detection).** `ThumbnailService.produceData` always reads size+mtime and recomputes
  the fingerprint when either diverges (lines ~303–324), re-rendering only when the content actually moved.
  But it only runs on an NSCache **memory-miss**, so a change to a file whose tile is warm in the cache
  isn't seen until eviction/relaunch.
- **Metadata path (no detection).** `MediaMetadataService.metadata(for:in:)` re-extracts only while
  `hasCompleteMetadata` is false, then freezes; `extract` never reads mtime or a fingerprint. A file shown
  only in **list mode** (or an image playlist that's always list) that is resized/optimized elsewhere keeps
  stale `width`/`height`/`fileSizeBytes` forever.
- **Scan (no detection).** `ModelContext+Reconcile.makeFile`/`writeDerivedFields` write only
  path/name/skip/order/cloud/tags — never the metadata fields. A rescan never refreshes them.
- **Preview (trusts stale cache).** `MediaPreview.contentSize` lets the model's cached `pixelSize` win when
  present, so a stale width/height gives the peek card the wrong aspect ratio regardless of any scan.

## Settled approach — scan-driven invalidation, four trigger sites

A shared primitive on `PlaylistFile` clears the derived state so the next display re-extracts from scratch:

- **`invalidateMetadata()`** — unconditional clear of `duration`, `width`, `height`, `fileSizeBytes`,
  `lastModified`, **and** `fingerprint`.
- **`invalidateMetadataIfStale(size:modified:)`** — compares against the cached baseline (`fileSizeBytes`,
  `lastModified`) and calls `invalidateMetadata()` on divergence; a no-op when there's no baseline yet
  (`lastModified == nil` → nothing cached to invalidate).

**Clearing the fingerprint is safe and adds no re-renders.** The disk thumbnail cache is content-keyed, so
the next gallery display recomputes the same fingerprint from unchanged bytes → disk-cache hit, no re-render.
Only genuinely changed content moves the fingerprint and re-renders. For a list-only playlist (never in
gallery) clearing it costs nothing.

The four sites that must invoke it:

1. **Scan (bulk).** `FileSystemService.enumerateMedia` already prefetches per-file resource values in one
   pass — add `.fileSizeKey` + `.contentModificationDateKey`; `MediaFile`/`ScannedFile` carry
   `fileSize`/`contentModified`; `reconcile` calls `invalidateMetadataIfStale` for each surviving file that
   has a baseline. Off-main, at launch-scan and every manual rescan.
2. **Preview open.** `MediaPreview.open` already resolves the folder+URL — before `contentSize` is read,
   stat that one file and call `invalidateMetadataIfStale`. On a change it clears the stale `pixelSize`, so
   `contentSize` falls back to the live source (decoded image size / mpv `dwidth`·`dheight`) instead of a
   stale shape. One syscall at user-initiated preview time — not a hot path.
3. **Thumbnail generation.** Keeps its own gate (it needs the file open to render). To make an *external*
   invalidation reach a **live** tile, **`GalleryCell.thumbnailKey` tracks `file.fingerprint`** so clearing
   it re-fires the cell's `.task`, misses the fingerprint-keyed memory cache, and regenerates. Cost:
   first-ever generation double-fires once (nil→compute→merge sets fp→key changes→one more pass, disk-cache
   hit so cheap, then settles). Accepted — chosen over "self-heal on recycle/relaunch" for instant refresh.
4. **Remove-audio.** An app-initiated in-place content change — `AppState.stripAudio` knows the content
   changed, so it calls `invalidateMetadata()` (unconditional, no stat) right after the swap; with site #3
   the tile regenerates and the badges refresh.
   **⚠ OPEN — resolve before wiring #4.** The Manager thumbnail is observed to switch to a different frame
   immediately after remove-audio, but the explicit trigger was **not** found in code: `stripAudio` does not
   `persistAndRefresh`/reconcile/clear fingerprint/evict the cache. The only visible-change path is
   `coordinator.jump` when the file is on the visual channel (the **player** surface, not the cached tile).
   Investigation of `CloudFileService` monitoring as a possible incidental trigger was cut short. Pin this
   down so #4 doesn't double up on (or fight) an existing mechanism.

## Sub-steps (test-first, one at a time)

- **S1. `extract` records `lastModified` (the baseline).** `MediaMetadataService.extract` reads
  `lastModified` alongside `fileSizeBytes` on every open, for every type. This mtime is the baseline the scan
  and preview compare against, so a file shown only in list mode finally has one. *Test:* a real video →
  `lastModified` set (alongside the existing duration/dimensions/size).
- **S2. Shared primitive + scan invalidation.** Add `invalidateMetadata()` /
  `invalidateMetadataIfStale(size:modified:)`; thread `fileSize`/`contentModified` through the enumerator →
  `MediaFile`/`ScannedFile`; `reconcile` invokes the stale check. *Tests:* the pure primitive (diverging pair
  clears the fields, matching pair leaves them, no baseline → no-op); a reconcile test on a changed file.
- **S3. Preview-open invalidation.** `MediaPreview.open` stats + calls the primitive before reading
  `contentSize`. *Test:* a stale-dimensioned file gets `pixelSize` cleared on open.
- **S4. Remove-audio invalidation + `thumbnailKey` tracks fingerprint.** `stripAudio` calls
  `invalidateMetadata()` post-swap; `GalleryCell.thumbnailKey` includes `file.fingerprint`. *Blocked on the
  ⚠ OPEN item.* *Test:* size badge / dimensions refresh after a strip (or assert the primitive call).

(Order: S1 gives every file an mtime baseline; S2 turns the scan into the general invalidator; S3/S4 cover
the two paths a scan can miss — preview, and the self-inflicted strip.)

## Notes / traps

- `MediaMetadata.merge` coalesces non-nil fields; `nil` means "not read." Invalidation must therefore write
  the fields to `nil` **directly on the model**, not via a `merge` of an empty bundle (a merge of nils is a
  no-op). Confirm the primitive sets the stored properties directly.
- Test traps (see CLAUDE.md): hold the `ModelContainer` for the whole test body; reconcile tests that touch
  models must not let a fire-and-forget task outlive the in-memory container. `MediaMetadataServiceTests`
  already models the real-video extraction pattern (samples under `test_media/videos`, matched by prefix).
- `MediaPreview` needs engines; prefer testing the pure primitive (S2) and asserting `pixelSize` is cleared
  rather than standing up the full preview.
