# Task — Cloud handling review follow-ups

Follow-ups from the `xhigh` code review of the `cloud-status-and-prefetch` branch (the
`cloud_offline_file_handling` work). The lettered steps are the open review findings; steps **I–K** are
related cloud gaps and features surfaced while discussing the review. Every item was scheduled as a step,
implemented one at a time, test-first. All steps are complete. (Done and removed:
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
duplicated in `PlayerView` folded into that shared view;
K — download-on-demand: `AppState.downloadFiles(_:)` (in `AppState+FileOps.swift`) filters to the
non-`.local` targets, opens one transient `folderAccess.withAccess` session (the browse path — a
non-playing playlist holds no `begin` session for `url(for:)`), calls
`cloudFileService.requestDownload(at:)` per target, and optimistically marks each `.downloading` for
immediate badge feedback (the live `NSMetadataQuery` runs only for a playing channel; `cloudStatus` is
`@Transient`, so it's an observation-only write the feed / next scan settles to `.local`). The Manager
list (`FileRowView`) and gallery (`GalleryCell`) cloud badge is now its own borderless `Button`
requesting that file's download — a distinct control that sidesteps the row's tap arbitration;
`FileContextMenu` gained a no-confirmation `Download` item shown only for a non-`.local` file, wired in
the Manager (multi-file `targets(for:)`) and the Visual Overlay (single file). `AppState.init` took a
`cloudFileService` test seam so the request is asserted against a recording requester.)
