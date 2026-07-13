# Task — Sequence provider & single-sequence refactor

A deferred refactor of how playback/display file sequences are derived, owned, and memoized.
Surfaced while discussing finding N of `cloud_review_followups.md` (prefetch re-fetching the whole
sequence per file switch), which turned out to be a symptom of a larger structural split rather than a
local inefficiency. **Not** part of the `cloud-status-and-prefetch` branch — its own future branch.

Status: **design, not started.** Direction is broadly agreed (below); a few questions remain open before
any implementation, and each shipped step will be test-first as usual.

## Motivation

Sequence derivation is split across two owners and duplicated, and one of the two sequences exists only
to serve a single narrow case:

- **AppState** memoizes three id-sequences (`managerFileIDsMemo`, `audioChannelFileIDsMemo`,
  `visualChannelFileIDsMemo`) against `sequenceVersion`, for the view surfaces (Manager center, audio
  overlay, Visual Overlay).
- **PlaybackCoordinator** re-derives `playlist.playbackSequence` fresh on every switch — once to find the
  target (`startFile` / `jump` / `fileAfter`) and again inside `setCurrentFile` for the prefetch horizon.
  It holds no memo and never sees `sequenceVersion`, so it cannot safely cache. That double-fetch per
  switch is finding N.

The coordinator deriving its own sequence is **correct**, not the smell: the engines advance autonomously
(natural EOF in `MPVPlaybackEngine`, the slideshow timer in `ImagePlaybackEngine`) and call
`source.fileAfter(...)` synchronously from `SourceNavigating.advanceToNext()`, with AppState nowhere in
that stack. So "what plays next" must be answerable below AppState. The smell is only that the *same*
sequence is derived twice within one synchronous operation, and that its memoization lives in a place the
engine-facing path can't reach.

## Established facts (verified)

- **`displaySequence` and `playbackSequence` diverge in exactly one case.** `playbackPredicate` returns
  "match nothing" only when `serviceFilter == .skipped`; for every other filter it *is* the display
  predicate. Every non-skipped filter already carries `!isSkipped`, so skipped files are only ever visible
  under the single Skipped chip. (`ModelContext+Sequence.swift`.)
- **`isSkipped` is a scan-time classification, never a user toggle.** Set once in
  `ModelContext+Reconcile.swift` as `scanned.mediaType != playlist.mediaType` — a wrong-type/unplayable
  file that happened to sit in the folder. No skip/unskip action exists anywhere. The only meaningful
  action on a skipped file is delete.
- **Two authorities drive the same engines through `PlaybackSource`.** The coordinator (playlist
  playback) and `MediaPreview` (the peek, whose `fileAfter`/`fileBefore` return `nil`). This is why the
  engine is deliberately AppState-unaware — the seam lets one engine be repurposed and unit-tested.

## Proposed design

### 1. A shared sequence provider

Introduce one collaborator (working name `PlaybackSequences`) that owns the sequence memo **and** the
version counter, injected into both AppState and the coordinator the same way `folderAccess` /
`globalSettings` / `cloudFileService` already are (constructed by AppState, passed to the coordinator's
`init`). It wraps the `ModelContext`, exposes memoized `sequence(of:)` (plus the Manager's transient mode
variants), and its `bump()` replaces `AppState.sequenceVersion &+= 1` in `persistAndRefresh`.

Consequences:

- AppState's three memo slots collapse into the provider's one cache (keyed by playlist + mode + version).
- The coordinator's find-target and prefetch reads hit the same memoized entry within one synchronous
  advance, so finding N's double-fetch disappears *for free* — no per-call stash, no AppState
  back-reference, no ownership inversion.
- The engine stays source-driven (answering #1): the engine talks to its `PlaybackSource`; the source's
  sequence answers come from the provider. The preview's engine-reuse and the engine's testability are
  preserved.

Open: exact cache shape (small keyed dict vs. per-consumer slots); whether `MediaPreview` also takes the
provider or keeps returning `nil` unchanged; how the provider is constructed in the coordinator tests
(which today build a coordinator with no AppState — the provider must be constructible from a bare
`ModelContext`).

### 2. Collapse the two sequences into one

Reclassify **Skipped** from a persisted `serviceFilter` into a transient Manager review mode, exactly like
find-duplicates (`duplicateSearchActive` → `duplicateSequence`). Untagged / invalid-tagging stay real
filters — they are subsets of *playable* files and never forced the split.

With Skipped no longer a playback-time filter, the effective filter is always skipped-excluding, so
`displaySequence == playbackSequence` everywhere and the second sequence evaporates:

- One `sequence(of:)`; `managerFileIDs` / `audioChannelFileIDs` / `visualChannelFileIDs` all read it
  (subject only to the Manager's transient duplicates/skipped mode swaps).
- `playbackPredicate`'s `{ false }` special case, and the display-vs-playback duality across
  `ModelContext+Sequence.swift`, go away.
- The center notice bar's "N skipped" enters the transient review mode instead of setting a filter.
- The name problem dissolves: there is one sequence, no `displaySequence` to rename.

Because skipped files are only ever deleted, the review mode needs just a list + delete; the in-player
Visual Overlay no longer needs a skipped-inclusive sequence at all (there was never anything to *do* with a
skipped file mid-playback).

Related cleanup (can be its own small step): gate file actions by applicability so inapplicable ones don't
show — e.g. "remove audio" on a video playlist, and anything but delete on a skipped file.

## Open questions to settle before implementation

1. **Migration for removing the `.skipped` `serviceFilter` case.** `filterState` is persisted on the
   `Playlist`; existing stores may hold `.skipped`. Decide whether to migrate it away or coerce a stored
   `.skipped` to "no filter" on load. (Changing the persisted model implies a schema version — see
   `doc/versioning.md`.)
2. **Where the transient skipped-review mode lives** (an AppState flag paired with duplicates) and whether
   the two review modes are mutually exclusive.
3. **Provider construction in tests** — the coordinator test suite builds a coordinator without AppState;
   the provider seam must stay as cheap to construct as the current direct `playlist.playbackSequence`.
4. **Scope of the action-gating cleanup** — fold into this task or split out.

