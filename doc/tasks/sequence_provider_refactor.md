# Task — Sequence provider & single-sequence refactor

A deferred refactor of how playback/display file sequences are derived, owned, and memoized.
Surfaced while discussing finding N of `cloud_review_followups.md` (prefetch re-fetching the whole
sequence per file switch), which turned out to be a symptom of a larger structural split rather than a
local inefficiency. **Not** part of the `cloud-status-and-prefetch` branch — its own future branch.

Status: **steps 1–4 shipped.** The general metadata-staleness gap review surfaced during step 4 is split
into its own task (`metadata_staleness_invalidation.md`). Each step is test-first as usual and implemented
one at a time after confirmation.

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

Because skipped files are only ever deleted(show in folder and rename are fine as well), the review mode needs just a list; the in-player
Visual Overlay no longer needs a skipped-inclusive sequence at all (there was never anything to *do* with a
skipped file mid-playback).

Related cleanup : gate file actions by applicability so inapplicable ones don't
show — e.g. "remove audio" is not applicable for a skipped file.

## Settled decisions

1. **Removing the `.skipped` `serviceFilter` case — migrate the persisted value, at the `Codable` seam,
   not via a `VersionedSchema` stage.** `filterState` is an *embedded `Codable` composite* on the
   `Playlist` `@Model` (`FilterState` struct → optional `ServiceFilter` enum), not a first-class SwiftData
   column. Two consequences follow, and both point away from a schema-version stage:
   - **SwiftData won't detect the change.** The attribute's schema hash is "a `FilterState` composite" —
     removing an enum case *inside* that blob doesn't change the SwiftData-level type, so no lightweight
     stage would even fire (same reason a `#Index`-only change needs the marker-entity hash bump — see
     `reference_swiftdata_index_not_applied_to_existing_store`).
   - **A stage couldn't rewrite the blob anyway.** Migration stages transform SwiftData attributes, not the
     inner `Codable` value of a composite; and the pinned "from" schema references the *live* `FilterState`
     type (as `SchemaV8` references live models), so once `.skipped` is gone the old blob can't decode there
     either.

   The real risk is purely at the JSON-decode boundary: an existing store holds
   `filterState.serviceFilter == "skipped"`, and synthesized `decodeIfPresent` **throws** on an unknown raw
   value (it returns `nil` only for an absent/null key, never for a present-but-invalid one — that is *not*
   the "decodes to nil from pre-triage filters" path, which is key-absence). So the migration is a custom
   `FilterState` (or `ServiceFilter`) decoder that coerces an unrecognized `serviceFilter` to `nil`
   ("no filter"). This is verified test-first as **step 1**: seed a raw store/blob holding `"skipped"`,
   observe the current decode behavior, then add the coercion and watch a stored `.skipped` load as no
   filter. No `SchemaVN` bump, no stage.

2. **The transient skipped-review mode is an AppState flag paired with duplicates, mutually exclusive with
   it.** A `skippedReviewActive` (working name) sits beside `duplicateSearchActive`; entering either exits
   the other (extend the existing `setDuplicateSearch` mutual-exit, or a shared setter). `managerFileIDs`'
   closure becomes three-way — duplicates → `duplicateSequence`, skipped → `skippedSequence`, else →
   `sequence(of:)` — routed through the same `memoizedSequence`. The center notice bar's "N skipped" enters
   this mode instead of calling `toggle(service: .skipped)`. A managed-playlist switch and a filter edit
   exit it, exactly as they exit find-duplicates today.

3. **Provider construction in tests — a design constraint, not an open choice.** The provider must be
   constructible from a bare `ModelContext` (the coordinator test suite builds a coordinator without
   AppState), staying as cheap as today's direct `playlist.playbackSequence`. Its `init` takes the
   `ModelContext` and nothing AppState-shaped; the version counter starts at zero and is bumped only
   through the provider. This is honored in the step design (below), not deferred.

## Implementation steps (test-first, one at a time, confirm before starting)

1. ✅ **Decode coercion for a stored `.skipped`.** `FilterState.init(from:)` decodes `serviceFilter`
   leniently (`try? decodeIfPresent`), coercing an unrecognized raw value to `nil`; the tag fields keep
   their synthesized defaults and `Encodable` stays synthesized. Covered by
   `FilterStateTests.filterStateCoercesAnUnrecognizedServiceFilterToNil` (observed red — `dataCorrupted` on
   the unknown value — then green) with a `filterStateDecodesARecognizedServiceFilter` guard. `.skipped`
   is still in the enum; this only proves the load path is safe once it's removed in step 2.
2. ✅ **Reclassify Skipped as a transient Manager review mode.** `skippedReviewActive` sits beside
   `duplicateSearchActive`, mutually exclusive through a shared `setReviewMode`; `exitReviewModes` leaves
   both on a filter edit / managed switch / scope switch. `managerFileIDs` routes three-way
   (`duplicateSequence` / `skippedSequence` / `sequence`). The `.skipped` enum case, the `playbackPredicate`
   `{ false }` special case, and the display-vs-playback duality are gone — one `sequence`/`sequencePredicate`
   /`sequenceFiles`/`sequenceMember`/`sequenceNotEmpty`/`resumeTarget` family. Skipped files are genuinely
   unplayable: `startFile` ignores an out-of-sequence request and `playFromManager` is a no-op in review.
   The center "N skipped" notice enters review; a "Showing skipped" bar exits it. Covered by
   `AppStateTests` (`skippedReviewSwapsCenterToSkippedFilesAndBack`, `reviewModesAreMutuallyExclusive`,
   `filterEditExitsSkippedReview`), `PlaybackCoordinatorTests.ignoresARequestToStartOnASkippedFile`
   (observed red — a skipped file played via the old `?? requested` fallback — then green), and the
   `skippedSequence` / collapse coverage in `SequenceStoreTests` / `PlaylistPlaybackTests`.

   **Concrete plan (naming settled with user):**
   - **Enum.** Remove `ServiceFilter.skipped` (and its `systemImage`/`label` arms), leaving `untagged` /
     `invalidTagging`. `isSkipped` the *column* and the skipped *count* both stay.
   - **`ModelContext+Sequence.swift` collapse.** Once `.skipped` is gone, `playbackPredicate ≡ displayPredicate`,
     so the display-vs-playback duality evaporates into one family:
     `displayPredicate`/`playbackPredicate` → **`sequencePredicate`**; `displaySequence`/`playbackSequence` →
     **`sequence`**; `displayFiles`/`playbackFiles` → **`sequenceFiles`**; `displayMember`/`playbackMember` →
     **`sequenceMember`**; `hasPlaybackFiles` → **`sequenceNotEmpty`**; `playbackResumeTarget` →
     **`resumeTarget`**. Add **`skippedSequence(of:)`** — the playlist's `isSkipped` files in `sortOrder`
     (list-only, no grouping). `Playlist` forwarders and `AppState.displaySequenceContains` →
     **`sequenceContains`** rename in step with these.
   - **Review mode (AppState).** `skippedReviewActive` beside `duplicateSearchActive`, **mutually exclusive**:
     a shared setter so entering either exits the other; a managed switch / scope switch / filter edit exit
     both. `managerFileIDs` routes three-way (duplicates → `duplicateSequence`, skipped → `skippedSequence`,
     else → `sequence`) through the same `memoizedSequence`.
   - **Skipped is unplayable (behavior change, red-first).** A wrong-type file must never reach an engine.
     Drop `startFile`'s `?? requested` fallback and ignore a `requested` file outside the sequence (start at
     the first playable file instead); guard `playFromManager` to a no-op while `skippedReviewActive`
     (list-only review — no thumbnails, no playback). The old test that asserted a skipped file *plays*
     (`startsARequestedFileOutsideThePlaybackSequence`) inverts to assert it does **not**.
   - **Notice bar.** The center "N skipped" notice enters review mode (not `toggle(service: .skipped)`); a
     "Showing skipped" bar with a Done mirrors the duplicates bar. The Manager action bar's Play loses its
     `serviceFilter != .skipped` guard (there is no skipped filter left to hide it under).
3. ✅ **Introduce `PlaybackSequences` (the shared provider).** A `@MainActor @Observable` class wrapping a
   bare `ModelContext`, owning one version-keyed cache (playlist + mode) and the version counter; its
   `bump()` replaces `AppState.sequenceVersion &+= 1`. AppState constructs it and passes it to the
   coordinator's `init` alongside `folderAccess` / `globalSettings` / `cloudFileService`. AppState's three
   memo slots and `sequenceVersion` fold into it (`managerFileIDs` / `audioChannelFileIDs` /
   `visualChannelFileIDs` and every `sequences.version` reader now read the provider); the coordinator's
   find-target (`startFile` / `jump` / `fileAfter` / `fileBefore` / `reconcile`) and `setCurrentFile`
   prefetch hit the same memoized entry within one synchronous advance, closing finding N — every
   production `reconcile`/advance is preceded by a `persistAndRefresh()`/`bump()`, so the memo is never
   stale there. The now-unused `Playlist.sequence` forwarder is removed. Covered by `PlaybackSequencesTests`
   (`bumpAdvancesTheVersion`, `sequenceIsMemoizedUntilBumped` — a saved-but-unbumped insert stays stale,
   proving the memo real, `modesAreMemoizedIndependently`); the coordinator suite's direct-`reconcile` tests
   `bump()` after their manual save to mirror `persistAndRefresh`.
   
4. ✅ **Skipped feature gating.** A skipped file is wrong-type for its playlist (`isSkipped ⟺ scanned.mediaType != playlist.mediaType`), so decoding it as the playlist's `mediaType` is doomed — the thumbnail already returns `nil` (wrong decoder) and duration/dimensions can never be read. Stop *attempting* that work, and hide the one file action that can't apply.

   > **Split-out:** reviewing this surfaced a *general* correctness gap — the metadata path and the folder scan never notice a file changed on disk (only the thumbnail path does), so list-only playlists freeze stale dimensions/size and the preview trusts a stale cached `pixelSize`. That work is **its own task now** — see `metadata_staleness_invalidation.md` — because it benefits every file type, not just skipped files, and keeps each change reviewable. This step stays scoped to the skipped gating; a1 here is already done and stands underneath the staleness layer that task adds on top.

   **Concrete plan (test-first, keyed on `PlaylistFile.isSkipped`):**
   - **a1. Size-only metadata for skipped — `PlaylistFile.hasCompleteMetadata(for:)`.** ✅ **DONE.** Returns `true` right after the `fileSizeBytes` guard when `isSkipped` (a wrong-type file records only size, so size alone completes it — no decode ever needed). Test `MediaMetadataServiceTests.skippedFileCompleteOnceSized` (observed red→green); `completenessGuardIsTypeAware` still green.
   - **a2. `MediaMetadataService.extract` reads only size for skipped.** ✅ **DONE.** `extract` gained an `isSkipped` argument; when set, it records `fileSizeBytes` and `guard`s out before the type-decoder switch. `metadata(for:in:)` passes `file.isSkipped`. Test `MediaMetadataServiceTests.extractReadsOnlySizeForSkippedFile` (observed red — the h264 sample decoded duration 15.183 / 720×1280 despite the flag — then green); the existing extract tests pass `isSkipped: false`. *(The staleness task's S1 later folds `lastModified` into this same read for every type.)*
   - **a3. No thumbnail for skipped — `ThumbnailService.thumbnail(for:in:)`.** ✅ **DONE.** Early-returns `(nil, MediaMetadata())` for a skipped file at the top of the entry point: no bookmark resolve, no file open, no produce; the gallery keeps its placeholder icon and the file's size comes solely from the metadata service. Test `ThumbnailServiceTests.skippedFileYieldsNoThumbnailAndNoRead` (observed red — the produce opened a readable file, rendered it, and reported size 274 + a fingerprint + a cache write — then green).
   - **b. Hide playable-only actions for a skipped file — `FileContextMenu`.** ✅ **DONE.** The playable-only actions live in one `if !file.isSkipped { … }` group, each keeping its own guard (currently just the video-only "Remove Audio"); Rename / Show in Finder / Download / Delete stay available for a skipped file. A view-structure gate, not logic — no helper, no unit test.

(Order rationale: a1 (done) makes skipped complete-once-sized so the metadata service stops re-opening it forever; a2 stops the wasted wrong-type decode; a3 is the visible move; b is the small UI gate.)

