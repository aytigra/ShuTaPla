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
H — drop/cancel tests gated on a positive pump-cycle signal;
I — thumbnail/metadata generation is cloud-aware: `MediaMetadataService.metadata(...)` and
`ThumbnailService.thumbnail(...)` gate on `cloudStatus == .local` at the service entry so an evicted
file is never read (metadata serves the cached bundle; the thumbnailer threads `isLocal` into
`produceData`, disabling the staleness gate and skipping both the fingerprint recompute and the
`renderThumbnail` on a disk miss — but still serving a disk-cache hit named by a stored fingerprint,
so an evicted folder shows the thumbnails generated while it was local). The gallery `thumbnailKey`
and the list's new `FileRowView.metadataKey` fold `\(file.cloudStatus == .local)` so the flip to
`.local` re-fires generation exactly once, on the local boundary. No gallery prefetch — evicted tiles
stay on placeholder art until playback or an explicit action makes the file local;
J — the Manager preview is cloud-aware like playback: `MediaPreview` conforms to `PlaybackSource` and
is set as both engines' `source`, resolving each file's URL and issuing
`cloudFileService.requestDownload(at:)` for an evicted file so the gate's arrival wait fires. Its
`fileAfter`/`fileBefore` return nil (the seam a later preview-navigation task fills in), preserving
"a peek never advances" — so the `engine.source = nil` line was dropped. `MediaPreviewView` overlays a
shared `CloudDownloadingPlaceholder` while `MediaPreview.cloudPendingFile` is set, on a 600 pt default
card when no dimensions are cached and latching to the media's true shape on arrival; the placeholder
duplicated in `PlayerView` folded into that shared view.)

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
