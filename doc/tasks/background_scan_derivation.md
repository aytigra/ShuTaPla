# Background scan derivation (design note)

Standalone refactor note, to be implemented after compact. Moves filename-tag
derivation into the background scan so it is applied uniformly to every file the scan
already enumerates, removing the per-rescan MainActor cost and the special-cased
"heal" path as well as three-fold duplication.

## Principle

The on-disk filename is the source of truth for a file's tags. The `Tag` relationship
and `taggingStatusCode` column are a denormalized index the tag/triage filters query
store-side (a `#Predicate`); chips display from `PlaylistFile.tagNames`, parsed from
the filename. Folder scan, create, and update all run as **background** operations (a
spinner covers them) so switching to or creating a playlist stays instant.

Derivation belongs in that background pass, applied to every file the scan already
walks — newly added, surviving, and migration-emptied alike. There is then no separate
"heal" operation and no per-scan gating: the first scan after a create or migration
writes the missing tags; a steady-state scan re-derives the same values and writes
nothing.

## Why this exists (the motivating cost)

The interim shape (the shipped tag-filter fix) derives on the MainActor: `update` →
`apply` calls `remirrorDerivedFields`, which loops **all** `playlist.files`, parses
each `fileName`, and evaluates `Set(file.tags.map(\.normalizedName))` — faulting the
`Tag` relationship for every file. That is an O(N) MainActor pass on every rescan
(materializing ~20k models and faulting ~20k relationships for a large playlist),
where the pre-fix code early-returned on an empty delta and did no per-file work.

Gating that pass to run "once" was considered and rejected: it is a band-aid for the
derivation being on the wrong actor. The scan already enumerates every file on disk to
compute the delta, so deriving each file's tags from the filename it is already
holding is marginal — and doing it there, off-main, removes the reason to gate.

And the duplication is threefold:

1. The scanner parses TagParser.fields(for: fileName) (background actor) → fills ScannedFile.tags/taggingStatus
2. makeFile copies those onto the model
3. remirrorDerivedFields re-parses the same filename to populate the same two fields

## Step 1 — derive in background, persist on the MainActor

The background scan returns per-file derived tags/status for **every current file**,
not just the added delta.

- Extend the scan contract: `FileSystemService.updatePlaylist` (and the initial
  `scanFolder`) returns, for each file currently on disk, `(relativePath, fileName,
  mediaType, cloudStatus, [tag names], TaggingStatus)` — the tag fields produced by
  the same `TagParser.fields(for: fileName)` the scanner already calls. Parsing every
  filename happens on the `FileSystemService` actor (background).
- The MainActor applies the result: for each file resolve the model (by relativePath /
  id), and write only the diffs — set `taggingStatus` when the code differs, reassign
  `file.tags = modelContext.tags(named:cache:)` when the normalized-name set differs.
  The divergence check stays (so an unchanged file is not rewritten), but the **parse**
  no longer runs on the MainActor. Then `rebuildTagFrequency`, save, bump
  `sequenceVersion`.
- `makeFile` becomes a naked-row builder (relativePath, fileName, isSkipped, sortOrder,
  cloudStatus) — no tags, no status, no cache. The single derivation site is the scan.
- `ScannedFile` drops `tags`/`taggingStatus`; the scanner is a pure lister. (Retire the
  scanner's tag-categorization assertions in `FileSystemServiceTests` — the logic stays
  covered by `TagParser`'s unit tests and the model-side derivation tests.)

This still leaves an O(N) MainActor *compare* (the divergence check faults the `Tag`
relationship), because the compare needs the stored tags, which live in the MainActor
context. Step 2 removes that.

## Step 2 — persist in background too

Give the scan its own `ModelContext` so it derives, compares, **and** writes off-main;
the MainActor is reduced to bumping `sequenceVersion` and re-fetching the ID sequence.

- A `@ModelActor` (e.g. `PlaylistScanActor`) constructed from the (Sendable)
  `ModelContainer`. It owns enumerate → derive → fetch-current-tags → diff → write →
  save, entirely on its own executor.
- Cross-context rules: models are not `Sendable` across contexts — pass
  `PersistentIdentifier`s, never `PlaylistFile`/`Tag`. After the actor saves, the main
  context sees the writes on its next fetch; the UI already re-fetches `displaySequence`
  on a `sequenceVersion` bump rather than holding model references, so the handoff is
  "background writes → save → MainActor bumps version → views re-fetch."
- Removes the last O(N) MainActor pass, and also the large-folder **create** insert
  stall (today a 20k create inserts 20k models on the main context regardless of
  gating; only a background context moves that off-main).
- Watch the test-trap classes in `CLAUDE.md` (a second context is exactly the
  orphaned-context / async-outlives-container territory): hold the container for the
  whole test body, `await` the actor's work before the body ends, and shut down cleanly.

## Orphan-`Tag` cleanup (folded in)

`Tag` rows are never deleted today; a tag dropped from every filename lingers (harmless
to filtering — it matches no files and is excluded from `tagFrequency` — but it
accumulates). Fold cleanup into the same background pass, where the full current tag set
is known, which sidesteps the race a separate sweep would invite. **`Tag` is shared
many-to-many across playlists**, so delete a tag only when its `files` is globally empty
— never per-playlist, or a tag another playlist still filters by would be yanked.

Do this as one bulk store operation, not by materializing every `Tag` and iterating.
SwiftData has no raw SQL, but `ModelContext.delete(model:where:)` is the equivalent — a
single batched delete pushed to the store:

```swift
try context.delete(model: Tag.self, where: #Predicate<Tag> { $0.files.isEmpty })
```

(`$0.files.isEmpty` is the join-existence test; fall back to `$0.files.count == 0` if a
predicate-translation issue surfaces.) Two caveats for implementation:

- **Batch delete operates on the saved store, not pending changes.** The pass that
  reassigns `file.tags` must be **saved first** so the now-orphaned tags are persisted
  before this delete runs; otherwise it won't see them.
- **Batch delete bypasses in-memory inverse maintenance** — fine here precisely because
  the targets have no `files`, so there is no `PlaylistFile.tags` to keep in step. The
  main context still re-fetches afterward (via the `sequenceVersion` bump), so it never
  reads a stale in-memory `Tag`.

## Testable

- A store whose files carry filename tags but an empty `Tag` relationship gains the
  relationship after one scan (the migration-heal case), via the background path.
- A steady-state rescan of an unchanged playlist writes nothing on the MainActor (and,
  after step 2, does no MainActor model work beyond the version bump).
- Derivation matches `TagParser.fields(for:)` for valid / untagged / invalid filenames.
- A create yields naked rows immediately and tags populate after the background scan.
- Orphan cleanup removes a tag dropped from every filename but keeps one still carried
  by another playlist's files.
