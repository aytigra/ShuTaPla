# Crash deleting a file from a playlist

## Report

Intermittent crash when deleting a file from a playlist:

```
Thread 1: Fatal error: This model instance was invalidated because its backing data
could no longer be found the store. PersistentIdentifier(… PlaylistFile/p1763 …)
```

User-observed conditions for the crash actually hit:
- Triggered from the **Manager** (list/gallery), not from a player/overlay.
- On a **video** file.
- The file was **not playing** — so it was never loaded into an engine.
- The file's **thumbnail and metadata were already generated** (cached) — so nothing was
  decoding in-flight at delete time.

`p1763` is a `PlaylistFile`. The message is SwiftData's trap when a *persisted property* is
read or written on a model instance whose row was deleted and the deletion **saved** (the
backing data is gone). It is a fatal `EXC_BREAKPOINT`, not a catchable error.

## Root cause (one defect, three reach paths)

Every candidate is the same underlying defect — **a `PlaylistFile` is touched after its row was
deleted and the deletion saved** — reached three different ways. The delete path
(`AppState+FileOps.deleteFiles`, `State/AppState/AppState+FileOps.swift:59`) does, per trashed
file: `file.playlist = nil` → `modelContext.delete(file)`, then `persistAndRefresh()` (saves +
`sequences.bump()`), then `coordinator.reconcile(playlistThatChanged:)`. After the save the row
is invalidated; anything still holding or re-resolving that instance and reading a persisted
field traps.

| # | Path | How the deleted file is reached | Site | Fits *this* report? |
|---|------|---------------------------------|------|---------------------|
| P1 | **Row / gallery re-render** | re-resolved via `model(for:)`, which returns a **non-`nil` invalidated instance** for a deleted id | `AppState.file(for:)` (`State/AppState.swift:268`) → `FileListRow`/`GalleryCell` body | **Yes** — no engine, no in-flight work, cached data |
| P2 | **In-flight decode** | strongly captured in a cancelled `.task` that still completes off-actor, then writes the model | `GalleryCell.swift:64` (`file.merge`) + `:69` (`hdrCache.record`), `MediaMetadataService.swift:42/46` | No (cached ⇒ nothing in flight) — still latent |
| P3 | **Deleting the playing file** | strongly held in `engine.currentFile` | `PlaybackCoordinator+Persistence.swift:43` (`file.lastPosition`) | No (not playing) — still latent |
| P4 | **Image-engine decode** | strongly held in `engine.currentFile`, written after `await` by the image decode task, which a delete does **not** cancel (image channel's `timelineEngine` is `nil`) | `ImagePlaybackEngine.swift:140` (`hdrCache.record(imageIsHDR:for:)` → `file.isHDR`) | No (from Manager, not the player) — still latent |

### P1 — the row re-render (primary suspect for the observed crash)

`AppState.file(for:)` resolves an id with `modelContext.model(for:)`, **not** a fetch:

```swift
func file(for id: PersistentIdentifier) -> PlaylistFile? {
    modelContext.model(for: id) as? PlaylistFile
}
```

A `fetch` drops deleted rows; `model(for:)` hands back the registered instance for that id
*even when it has been deleted* — an invalidated object, non-`nil`, that traps on the first
persisted-property read.

The data source itself is correct: `persistAndRefresh()` bumps `sequences.version`, and
`managerFileIDs` re-derives through `sequence(of:)` → `identifiers(matching:)`
(`Models/queries/ModelContext+Sequence.swift:29`), a `fetchIdentifiers` that **excludes** the
deleted row. So the deleted id leaves the list. The race is the **removal transition**: SwiftUI
re-evaluates the *outgoing* row's body one last time with its old id. `FileListRow`
(`FileListRow.swift:45`) / `GalleryCell` calls `appState.file(for: deletedID)` → `model(for:)`
→ invalidated instance → `if let file` succeeds → badges/caption read `file.fileName`,
`file.pixelSize`, `file.duration`, `file.isHDR` → trap. Timing-dependent ⇒ "sometimes."

Same resolver backs `ManagerSelectionPreview` (`file(for:)` over the selection), so the fix at
`file(for:)` covers every render path at once.

### P2 — in-flight thumbnail/metadata (latent)

Both Manager cells run a `.task` capturing the `PlaylistFile` strongly, `await` an off-actor
decode, then write the model:
- `GalleryCell.swift:64` runs `file.merge(result.metadata)` **before** its `guard
  !Task.isCancelled` (`:68`) — deliberately, so a cancelled task still records the fingerprint —
  so a delete during generation resumes and merges into the invalidated model. The same task
  has a second pre-guard write, `hdrCache.record(hdr, for: file)` (`:69`), which sets
  `file.isHDR` — same trap, same fix.
- `MediaMetadataService.metadata` (`:42` `file.merge(found)`, `:46` `return file.cachedMetadata`)
  is called from both `GalleryCell.swift:76` and `FileRowView.swift:69`; the pre-`await`
  reads (`hasCompleteMetadata`, `cloudStatus`) are safe, the post-`await` writes/reads are not.

Not the cause of the reported crash (cached ⇒ no generation in flight) but the same defect.

### P3 — deleting the currently-playing file (latent)

Delete the playing file on a **video/audio** channel → `reconcile` sees `currentFile` left the
sequence → `jump(playlist, to: first)` → `persistTimelinePosition(from:)`
(`PlaybackCoordinator+Persistence.swift:39`) reads `file.lastPosition` on the just-deleted
`engine.currentFile` before the new file loads → trap. The **image** channel's
`timelineEngine(of:)` is `nil`, so *this coordinator persistence path* no-ops. Not the reported
crash (file wasn't playing) but a real latent crash on the same pattern.

### P4 — image-engine decode writes the model post-`await` (latent)

The one path where "image deletes are safe" does not hold. `ImagePlaybackEngine.decode()`
calls `hdrCache.record(imageIsHDR: for: self.currentFile)` (`ImagePlaybackEngine.swift:140`),
which sets `file.isHDR` (a persisted property) and `trySave()`s, **after** an `await` and with
no validity guard. The image channel's reconcile has a `nil` `timelineEngine`, so a delete of
the displayed image does **not** cancel the in-flight decode — `self.currentFile` still points
at the invalidated row when the decode resumes and writes `file.isHDR` → trap.

P3's "image deletes are safe" is specifically about the coordinator's
`persistTimelinePosition` no-op; it does not cover this in-engine write. Same defect family,
guarded the same way (`guard file.isValid` after the `await`, before the `isHDR` write).

## Decisive experiment (run before writing any fix)

The whole fix hinges on one unknown that must not be guessed: for a **deleted-and-saved** id,
does `modelContext.model(for: id)` return `nil` or a non-`nil` invalidated instance — and is
`.modelContext` a **safe (non-trapping)** read that reports the invalidation (`== nil`)?

Probe (read-only, safe — it never reads a persisted property, so it cannot trap/hang the host):
insert a `PlaylistFile` → `save` → `delete` → `save` → inspect `model(for: id)` and its
`.modelContext`.

### Experiment result (run 2026-07-26, `DeletedModelResolutionTests`) — P1 confirmed, seam refuted

For a deleted-and-saved id:
- `model(for: id)` returns a **non-`nil`** invalidated instance → **P1 is a real trap.** ✓
- But **every instance-metadata seam still reports the object as live**, so `.modelContext != nil`
  is the wrong seam:
  - `.modelContext` — stays **non-`nil`** (refutes the proposed `isValid`).
  - `.isDeleted` — stays **`false`**.
  - `registeredModel(for:)` — still **returns the instance**.
- The **only** thing that reflects the deletion is a **fetch keyed on `persistentModelID`**
  (returns empty). `persistentModelID` itself stays a safe (non-trapping) read on the
  invalidated instance, so a `fetchCount` keyed on it is a valid, non-trapping validity check.

**Pending-record safety of the P1 fetch-resolver** (the constraint: it must not break the
call sites that rely on `model(for:)` resolving not-yet-saved records). Verified in the same
tests — an object-returning fetch keyed on `persistentModelID` with the **default
`includePendingChanges = true`** matches `model(for:)` on every state that matters:

| State | fetch-by-`persistentModelID` |
|-------|------------------------------|
| Saved, live | resolves (same instance) |
| **Unsaved insert** (temporary id) | **resolves** — temporary id matches under `includePendingChanges = true` |
| **Dirty saved** (modified, unsaved — e.g. mid-metadata-merge) | **resolves, same `===` instance, unsaved edit intact — no refault** |
| Deleted + saved | returns `nil` |

The refault trap (CLAUDE.md) bites only at `includePendingChanges = false`; the default is
`true`, so the resolver never refaults a dirty row.

## Proposed fix (corrected after the experiment)

The seam is **fetch-based**, not `modelContext != nil`. Two shapes, one idea (the row still
exists in the store):

```swift
extension PlaylistFile {
    /// A deleted-and-saved instance keeps a live-looking context/registration but its row is gone;
    /// reading a persisted property on it traps. Only a store fetch reflects the deletion.
    var isValid: Bool {
        guard let context = modelContext else { return false }
        let id = persistentModelID
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
```

- **P1 (central):** resolve `file(for:)` by a **fetch** keyed on `persistentModelID` instead of
  `model(for:)` — a deleted row simply fetches empty and the resolver returns `nil`, with no seam
  needed at the call site. Protects every row/cell/`ManagerSelectionPreview` render in one place.

- **P1 (central):** guard the resolver so an invalidated instance reads as absent —
  `file(for:)` returns `nil` unless `isValid`. Protects every row/cell/`ManagerSelectionPreview`
  render in one place.
- **P2:** after each `await`, `guard file.isValid` before `file.merge` /
  `hdrCache.record(hdr, for: file)` / `file.cachedMetadata` (skipping the writes on a deleted
  file is correct — no record to hold the fingerprint/`isHDR`, so the orphan sweep reclaims the
  thumbnail).
- **P3:** fold `file.isValid` into `persistTimelinePosition`'s existing guard (also hardens the
  periodic `persistLivePositions` loop against a raced deletion).
- **P4:** after the decode `await` in `ImagePlaybackEngine.decode`, `guard file.isValid` before
  `hdrCache.record(imageIsHDR:for:)` writes `file.isHDR`.

## Testing notes

Trap-class bug: the clean red reproduction is a fatal `EXC_BREAKPOINT` that crashes the test
host and **hangs the run** (CLAUDE.md trap discipline), so the observed "red" is the production
report plus the traced mechanism — not an automated failing test. What is runnable:

1. **The load-bearing assumption** (the decisive experiment above) — safe, red/green.
2. **`isValid` behaviour** — a live file reports `true`, a deleted-and-saved file reports
   `false`, and reading `isValid` on the deleted file is itself non-trapping.
3. **Regression** — a valid file still resolves and merges normally through the guarded paths.

Hold the `ModelContainer` for the whole test body (trap class 1); prefer the image-playlist
coordinator path for any P3 behaviour test (trap class 3).

## Status

Status legend: `[ ]` open · `[C]` confirmed (experiment/red done) · `[R]` refuted · `[F]` fixed · `[S]` skipped.

- `[C]` **Decisive experiment** — done (`DeletedModelResolutionTests`, 2 tests green). P1 trap
  confirmed; the `modelContext != nil` seam refuted; corrected seam is a `persistentModelID` fetch.
- `[F]` **P1** — `file(for:)` resolved by a `persistentModelID` fetch (`AppState.swift`). Regression
  `DeletedModelResolutionTests.appStateResolverDropsDeletedRow` (deleted-saved id → nil); pending-record
  parity covered by the other 4 tests. Build clean, no new navigator warnings.
- `[ ]` **P2** — post-`await` `isValid` guards in `GalleryCell` (`file.merge` + `hdrCache.record`) / `MediaMetadataService`.
- `[ ]` **P3** — `isValid` in `persistTimelinePosition`.
- `[ ]` **P4** — post-`await` `isValid` guard in `ImagePlaybackEngine.decode` before `hdrCache.record`.

Experiment done and doc updated with the corrected fetch-based seam — awaiting user confirmation
on scope/order before implementing P1. On its own branch (`delete-crash-fix`).
