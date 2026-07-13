# Task — Cloud handling review follow-ups

Follow-ups from the `xhigh` code review of the `cloud-status-and-prefetch` branch (the
`cloud_offline_file_handling` work). The lettered steps are the open review findings; steps **I–K** are
related cloud gaps and features surfaced while discussing the review. Every item is scheduled as a step
below; each step is written but **not started — implementation begins only on explicit go-ahead**, one
step at a time, test-first. Steps are independent, so they can be taken in any order. (Done and removed:
A — pending-load resume-position clobber; B — dead `CloudFileService` environment injection;
C — list cloud badge folded into the fixed-width file-size column so it adds no width and keeps the
columns aligned; D — `isLooping` reset deferred to arrival during a pending load;
E — live-feed update folds only the changed/added delta and resolves it with a scoped fetch instead
of faulting `playlist.files` (plus a CLAUDE.md rule against main-actor `playlist.files` in hot paths);
F — advance/previous/jump/start/switch/reconcile walk the `[PersistentIdentifier]` playback sequence and
resolve models lazily via `model(for:)` (the `availableFile`/`prefetchTargets` selectors re-typed to
take `[PersistentIdentifier]` + a `resolve:` closure) instead of materializing the whole sequence per
advance; `restoreTarget` became a store-side `ModelContext.playbackResumeTarget(of:atOrAfter:)` — a
bounded `fetchLimit: 1` fetch plus a `playbackSequence.first` wrap, the sort bound threaded through the
effective-filter predicates as `atOrAfter minSortOrder: Int = .min`; `ModelContext.playbackFiles` /
`displayFiles` and the `Playlist.playbackFiles` forwarder are now marked test-only (no production
callers). The `fileExists` stat review finding 3 flagged was confirmed a non-issue and left as-is;
G — misplaced `availableFile`/`prefetchTargets` doc comment;
H — drop/cancel tests gated on a positive pump-cycle signal.)

## Step I — Make thumbnail/metadata generation cloud-aware (from the background note)

**Problem.** The thumbnail and metadata subsystems are cloud-**un**aware, and that's two concrete
defects, not just a missing feature:

1. **They attempt work that must fail for an evicted file.** `GalleryCell`'s `.task(id: thumbnailKey)`
   (`GalleryCell.swift:43`) runs `thumbnails.thumbnail(...)` (`:54`) and, when metadata is incomplete,
   `metadataService.metadata(...)` (`:72`) with no `file.cloudStatus` check. For a file that is
   evicted and was never local, `ThumbnailService.produceData` resolves the bookmark and does an
   uncoordinated read whose `contentFingerprint()` / decode can't succeed — wasted bookmark-resolve +
   read + decode attempt, main-actor merge of an empty result, every time such a cell appears. The
   list surface (`FileRowView` → metadata) has the same blind spot.
2. **They never refresh when the file flips to `.local`.** `thumbnailKey` is
   `"\(file.id)|\(file.relativePath)"` — no cloud component — so when the bytes arrive and
   `cloudStatus` flips `.downloading → .local`, the `.task` does **not** re-fire, and the placeholder
   art / empty badges persist until an unrelated reload (rename, path change, relaunch).

**Plan (settle the seam before implementing).**

- *Skip the doomed attempt.* Don't generate a thumbnail or extract metadata for a file whose
  `cloudStatus != .local`. Decide the seam: gate at the service entry points (`thumbnail(...)`,
  `MediaMetadataService.metadata(...)`) so both the gallery and the list benefit from one guard and
  return an empty/`nil` result the callers already handle as "show placeholder / fall back to persisted
  values" — vs. gating in each view's `.task`. Prefer the service-level guard (deeper, one place,
  covers every caller) unless it disturbs a caller that legitimately reads a cache hit without a live
  file. A cached thumbnail / persisted metadata for an already-seen file must still be served (the disk
  cache is fingerprint-keyed and independent of current cloud state) — only the *fresh read* is
  skipped when evicted.
- *Refresh on arrival.* Fold `file.cloudStatus` into the gallery `.task` id (and the list's metadata
  trigger) so the flip to `.local` re-runs generation and the tile swaps placeholder → real thumbnail
  and empty → real badges on its own. `cloudStatus` is already Observation-tracked, so the `.task(id:)`
  re-fires without extra plumbing.
- *No gallery prefetch.* The gallery must **not** request downloads to fill in thumbnails/metadata for
  evicted files. An evicted folder means "keep in cloud, load on demand"; pulling files down just to
  render tiles would materialize the whole folder locally and negate the point of keeping it in the
  cloud. Evicted tiles stay on placeholder art until the file becomes local through playback (the
  playback-horizon prefetch in `setCurrentFile`) or an explicit user action — the skip-and-refresh
  pair above is the whole of this step.

**Test-first.** The extraction cores are stateless and already seam-tested. Add: (a) a test that a
non-`.local` file yields no read attempt / empty result from the gated entry point (observe the
current code doing the wasted read first, then gate); (b) a test that flipping a file's `cloudStatus`
to `.local` changes the task id / re-trigger key so the view would regenerate. Keep trap-safe per
CLAUDE.md (registrar-routed `cloudStatus` doesn't fetch; use non-inserted identity fixtures).

## Step J — Make the Manager preview cloud-aware, like playback

**Problem.** The Manager "peek" (`MediaPreview`, opened by `[space]` on a single selected file) does
**not** handle an evicted file the way playback does:

- `MediaPreview.open` (`MediaPreview.swift:96`) builds the URL and calls `engine.load(file, at: url)`
  directly. The video engine's `load` routes through `CloudLoadGate` (so it *defers*), but preview
  never calls `requestDownload` — only playback issues that, via `setCurrentFile` /
  `PlaybackCoordinator.requestDownload`. So previewing an evicted video parks the engine pending with
  no download ever requested: it waits forever, nothing plays, and no placeholder communicates why.
- The image branch (`imageEngine.load`) uses `ImagePlaybackEngine`, which has **no** cloud gate at
  all, so it just attempts to decode the evicted placeholder and fails to a blank card.

**Plan (settle before implementing).** Give preview the same open-on-cloud behavior as playback:
show a placeholder card, **request the download** for the file's URL, and start the actual render only
once the file is `.local` — reusing the shared machinery rather than duplicating it. Decide the seam:

- Video: the engine already gates through `CloudLoadGate`; the missing piece is the `requestDownload`
  call. Route preview's engine load through a source/hook that issues the download (the coordinator's
  `requestDownload` resolves URL via `folderAccess`; preview holds its own `ScopedFolderAccess`, so a
  small preview-owned download call over `cloudFileService.requestDownload(at:)` may be cleaner than
  borrowing the coordinator). Once `cloudStatus` flips `.local`, the gate performs the deferred load.
- Image: `ImagePlaybackEngine` needs an equivalent evicted-file gate (or a pre-check in
  `MediaPreview.open` that, for a non-`.local` image, requests the download, shows the placeholder, and
  loads once local) — mirror whatever the video gate does so both media types behave identically.
- Preview UI (`MediaPreviewView`) shows a cloud/placeholder state while pending, replaced by the media
  on arrival (`cloudStatus` is Observation-tracked, so the card updates itself).

**Test-first.** Preview's engines are injectable (`makeVideoEngine`, `imageEngine`). Cover: opening a
preview on a non-`.local` file requests exactly one download and stays on the placeholder (no play)
until the status flips; flipping to `.local` performs the load. Keep trap-safe per CLAUDE.md — use the
window-free/image engines, `defer { shutdown() }`, and non-inserted fixtures; never a real
`VideoPlaybackEngine` in the test host.

## Step K — Download-on-demand from the cloud badge and a context-menu command

**Problem / feature.** There is no user-driven way to pull an evicted file local short of playing it.
Two entry points to add:

1. **Tap the cloud badge to download.** `CloudStatusBadge` is documented as "A status readout, not a
   control" (`CloudStatusBadge.swift:5`), shown in the list (`FileRowView:80`) and gallery
   (`GalleryCell:106`). Make the badge tappable so clicking the `icloud` / `icloud.and.arrow.down`
   glyph requests that file's download (a no-op / already-local for `.local`, where the badge isn't
   shown anyway). Update the type's doc comment away from "not a control" to match.
2. **A "Download" context-menu command with multi-file support.** `FileContextMenu` already takes
   `onRemoveAudio` / `onDelete` closures fed by `targets(for: file)` (the multi-selection when the
   clicked row is part of it, else just that row — `FileCollectionView.swift:263`). Add a **Download**
   item beside them that requests download for every target that isn't `.local`. Model it on Delete's
   multi-file targeting, **but with no confirmation dialog** (a download is non-destructive and cheap
   to reverse by eviction) — so it goes straight through, unlike `confirmDelete`.

**Plan (settle before implementing).** Add one `AppState` entry point — e.g.
`downloadFiles(_ files: [PlaylistFile])` — that resolves each file's URL and calls
`cloudFileService.requestDownload(at:)` (or the coordinator's `requestDownload`), skipping `.local`
ones. Wire both the badge tap and the new menu item to it. Settle: which service owns the
selection-download call (the coordinator already resolves URLs via `folderAccess`, but requires an
active scoped session for the playlist — confirm the managed playlist's session is available when
browsing, or resolve the URL through the same bookmark path the thumbnailer uses). Respect the
"single `onTapGesture`, branch on click count" convention if the badge tap shares a row's gesture
region; a distinct control (the badge as its own `Button`) sidesteps the gesture-arbitration trap
entirely — prefer that.

**Test-first.** The selection→download resolution is pure list logic: cover that `downloadFiles`
requests a download for each non-`.local` target and skips `.local` ones (inject a recording
`requestDownload` seam), and that `FileSelection.actionTargets` still drives the multi-file set the
menu passes. Badge-tap wiring is a view concern (manual check), but the underlying
`downloadFiles` call is unit-tested. Trap-safe fixtures per CLAUDE.md.
