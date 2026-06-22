# Content-fingerprint thumbnail sharing (design note)

Standalone design note, not yet scheduled. Captures a cheap content fingerprint
for media files and a re-key of the thumbnail cache around it, so the same file
referenced by two playlists shares one generated thumbnail regardless of folder
nesting. Related to — and a natural precursor of — the many-to-many `MediaFile`
identity discussed at the end.

## Problem

`ThumbnailService` keys its on-disk cache by relative path:

```swift
// ThumbnailService.cacheKeyComponents
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
  on disk. The cache has no eviction (the only `removeItem` drops a corrupt
  cache file before regenerating), so stranded entries accumulate until macOS
  purges the Caches directory under disk pressure.
- **Cross-folder key collision.** The key omits the folder bookmark, so two
  *different* files in two folders that happen to share a relative path, size,
  and modification date hash to the same entry and can cross-paint. (The
  in-memory `NSCache` key avoids this by including `playlist.id`; the disk key
  does not.)

A content fingerprint addresses all three: it is independent of which folder
references the file, stable across rename/move, and derived from the bytes so a
collision requires genuinely matching content.

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
    func contentFingerprint(windowBytes: Int = 64 * 1024) -> String? {
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

## ThumbnailService re-key

`cacheKeyComponents` already runs inside a resolved-bookmark, scoped-access
closure (`produceData`), so the `URL` is in hand and the read costs nothing
extra in setup:

```swift
private nonisolated static func cacheKeyComponents(
    fileURL: URL, relativePath: String, maxPixelSize: Int
) -> String {
    // Content identity, independent of folder nesting and stable across rename.
    // Fall back to the relative path + modification date when the file can't be
    // read for a fingerprint (it then can't be thumbnailed either, but keying it
    // distinctly avoids colliding unrelated unreadable files).
    if let fingerprint = fileURL.contentFingerprint() {
        return digest("\(fingerprint)|\(maxPixelSize)")
    }
    let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    let stamp = modDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "0"
    return digest("\(relativePath)|\(stamp)|\(maxPixelSize)")
}
```

No schema change, no migration: existing `.heic` files keyed by the old scheme
simply miss once and are regenerated under the fingerprint key (the old files
are stranded, same as any other cache miss — see GC below).

### Cost trade-off

The disk-cache key is computed only on an **in-memory miss** — `cachedThumbnail`
serves warm scroll hits from the `NSCache` with no disk I/O and never computes
this key. So the added cost is one 128 KB read per cold load (first time a cell
is shown in a session), which already pays a disk read for the `.heic` body on a
hit and a full decode on a miss. The fingerprint read is modest against either.

If profiling shows the cold-load read matters, persist the fingerprint on the
file record (next section) and read it from the model instead of the file.

## Bridge to many-to-many `MediaFile`

The fingerprint is the same identity a shared `MediaFile` record would key on.
The cheap step above (service-only re-key) and the larger schema change compose:

1. **Now / cheap:** the re-key above. Shares thumbnail *generation* across
   playlists regardless of folder nesting. Pure `ThumbnailService` change.
2. **Later, if duration re-extraction or record duplication justifies it:**
   persist `fingerprint` on `PlaylistFile` (computed once during scan/Update),
   then split intrinsic file state (`duration`, dimensions, parsed tags,
   thumbnail) into a `MediaFile` keyed by fingerprint, with a join entity
   carrying the per-playlist state (`relativePath`, `sortOrder`, resume
   position). Dedup on scan becomes a fetch-or-create against the fingerprint.
   This is the change with real product decisions attached (do tag edits and
   resume positions follow the file across playlists, or stay per-playlist) and
   is out of scope for this note.

Persisting the fingerprint on the file record is the load-bearing prerequisite
for step 2 and also retires the cold-load read in step 1, so it is the natural
seam between the two.

## Orphan GC (optional, independent)

Whichever keying is used, the disk cache never shrinks on its own. A simple
sweep closes that gap: on launch (or idle), enumerate `.heic` files in the cache
directory whose access date is older than a threshold and remove them. With
fingerprint keys this is safe and self-correcting — a removed entry that is still
referenced regenerates on next view. This is independent of the re-key and can
ship separately.

## Testable

- `contentFingerprint` is stable across a rename/move of the same bytes, differs
  for differing content, and differs for same-window-but-different-length files
  (size is hashed). Exercised directly against `test_media/videos/` fixtures and
  small synthetic files.
- Two playlists referencing the same file at different relative-path depths
  produce the same `cacheKeyComponents` and share one `.heic` (one generation).
- An unreadable file falls back to the path+modDate key without trapping.
- (GC, if built) a stranded `.heic` past the age threshold is removed and
  regenerates on next request.
