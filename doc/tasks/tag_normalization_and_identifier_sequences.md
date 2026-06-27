# Task 17 — Tag normalization & identifier-based display sequence

Performance refactor. Replaces the whole-set, in-memory derivation of a playlist's
display/playback order with a store-side, identifier-only one that never materializes a
large playlist at once. Summarized in [`index.md`](index.md#task-17); this note is the
implementation design.

## Problem

`Playlist.displaySequence` (and `playbackSequence`, `hasPlaybackFiles`,
`serviceFilterCounts`) walk the whole `files` relationship and read each `PlaylistFile`'s
SwiftData-backed properties:

```swift
// Extensions/Playlist+Playback.swift
for file in files {
    let skipped = file.isSkipped
    …
    keep = Self.tagsMatch(Set(file.tags.map { $0.lowercased() }), selected: selected, mode: mode)
    …
}
kept.sort { $0.order < $1.order }
```

Each property read is far costlier than a plain field access (~0.8µs), and a full
materialization of a large playlist (~20k files) costs ~500ms cold. The Manager and the
overlays re-derive on every scope/playlist switch (`AppState.managerFiles`,
`visualChannelFiles`, `audioChannelFiles` all read these properties), so a large playlist
hitches on each switch.

The only approach under the per-object materialization floor is to **not** materialize the
set: fetch just the ordered identifiers (`fetchIdentifiers`, ~8ms for 20k) and resolve only
the rows actually on screen. Two storage shapes block that today:

- **Tags are an inline `[String]` blob** (`PlaylistFile.tags`), so a tag filter can't be a
  store predicate — it has to be a per-file Swift comparison.
- **`taggingStatus` is a `Codable` `String` enum.** A `#Predicate` comparing it throws
  `unsupportedPredicate` ("Captured/constant values of type 'TaggingStatus' are not
  supported") — the same limitation `ModelContext+Playlists.swift` already documents for the
  stored `MediaType` enum. Relationship scoping (`$0.playlist?.persistentModelID == pid`)
  and `Bool` (`isSkipped`) predicates already work.

## Approach

Normalize tags into a queryable `Tag` relationship, store `taggingStatus` as a scalar, then
derive the sequences store-side as ordered `[PersistentIdentifier]` and resolve rows lazily.

SwiftData models expose `.modelContext`, so the store-side methods are reached via
`playlist.modelContext` at existing call sites — no `ModelContext` needs injecting (the
coordinator holds none today). `TagParser` stays the single source of truth for parsing and
rewriting tags from filenames; both the `Tag` relationship and the chip display derive from
it, and on-disk filename casing remains authoritative.

**No data migration.** Filenames are the source of truth for tags, so the old `tags:
[String]` field is dropped and the relationship repopulates from a normal scan/Update (which
already runs whenever a playlist is loaded). Existing data is simply re-parsed.

The work lands in three stages, each building and passing tests before the next.

### Stage A — `Tag` entity + scalar `taggingStatus` (behavior preserved)

- **`Models/Tag.swift`** — `@Model final class Tag` with `@Attribute(.unique) var
  normalizedName: String` (lowercased) and `var name: String` (first-seen casing, display
  only), plus the inverse of the many-to-many to `PlaylistFile`. Tags are shared across
  files/playlists, deduped by `normalizedName`.
- **`Models/PlaylistFile.swift`** — replace `var tags: [String]` with
  `@Relationship(inverse: \Tag.files) var tags: [Tag] = []`; replace the stored
  `taggingStatus` with `var taggingStatusRaw: Int` and a non-stored
  `var taggingStatus: TaggingStatus { get/set }` that maps to/from the raw value (keeps the
  enum API at every read site). Drop `tags` from `init` — the relationship is assigned after
  insert, once the context can resolve `Tag`s. Add `var tagNames: [String]` =
  `TagParser.fields(for: fileName).0` for **display order** (the relationship is a set; the
  filename is the order source of truth).
- **`Models/Enums.swift`** — back `TaggingStatus` with an `Int` raw value for storage while
  keeping its existing API.
- **`Extensions/ModelContext+Tags.swift`** (new) — `tag(named:)`, find-or-create a `Tag` by
  `normalizedName`, so scan/rename resolve `[String]` → `[Tag]` without duplicate rows.
- **Write sites (`AppState`)** — scan and `applyRename` resolve parsed tag strings to `Tag`s
  via the helper; `rebuildTagFrequency` counts normalized `file.tags` names; the
  rename-collision check reads `$0.name`.
- **Read sites (views)** — `FileRowView` chips render from `file.tagNames`; `TagEditorView`
  common-tag math uses normalized names. `TagChips`/`TagChip` keep their `[String]`/`String`
  API.
- **Schema** — add `Tag.self` to `App/ShuTaPlaApp.swift` and every test `Schema([...])`.

Behavior is identical to today's after this stage; only storage shape changes.

### Stage B — store-side sequences via `fetchIdentifiers` / `fetchCount`

- **`Extensions/ModelContext+Sequence.swift`**:
  - `displaySequence(of:) -> [PersistentIdentifier]` and `playbackSequence(of:)` via
    `fetchIdentifiers(FetchDescriptor(predicate:, sortBy: [SortDescriptor(\.sortOrder)]))` with
    `includePendingChanges = false`.
  - `hasPlaybackFiles(in:) -> Bool` and `serviceFilterCounts(for:)` via `fetchCount`.
  - `displayFiles(of:)` / `playbackFiles(of:)` resolve the identifiers to `[PlaylistFile]` for
    callers that need the models (the coordinator, and the `AppState` accessors until Stage C
    makes the views lazy).
  - One private `#Predicate<PlaylistFile>` builder from a playlist: scope by
    `$0.playlist?.persistentModelID == pid`; triage via the `taggingStatusCode` / `isSkipped`
    scalars; tag filter over the relationship —
    - OR: `file.tags.contains { names.contains($0.normalizedName) }`
    - AND: `file.tags.filter { names.contains($0.normalizedName) }.count == required`,
      where `names` is deduped and `required = names.count`. A nested
      `names.allSatisfy { file.tags.contains { … } }` traps at fetch time
      ("Unsupported subquery collection expression type") — CoreData can't translate an
      `allSatisfy` over a captured array whose body is itself a relationship subquery — so AND
      is one flat `SUBQUERY(tags, …).@count == required` instead.

    where `names` is a captured `[String]` constant (which `#Predicate` allows). The triage
    `serviceFilter` (when set) overrides the tag filter; `playbackSequence` is the display
    predicate with skipped files dropped, and is empty under the skipped triage filter.
- **`Playlist+Playback.swift`'s computed properties are retired.** Call sites read store-side:
  `AppState` `managerFiles`/`visualChannelFiles`/`audioChannelFiles` and the current-file/contains
  checks resolve through `modelContext`; `PlaybackCoordinator` reaches the store via
  `playlist.modelContext?.playbackFiles(of: playlist) ?? []`.
- **Save before derive.** `AppState.persistAndRefresh()` saves and bumps a reactivity signal;
  mutation paths (`filterChanged`, tag edits, `reshuffle`, scan delta, file delete, playlist
  delete, playlist creation) call it once they reshape membership/order — and before any
  coordinator reconcile/advance — so the `includePendingChanges: false` fetches see the change.
  The effective filter itself is read live off the model into the predicate, so a filter edit
  needs no save for the *predicate* to reflect it; only the file *rows* must be persisted.
- **Reactivity signal.** The store-side fetches aren't tracked by Observation the way a walk over
  the `files` relationship was, so the `AppState` accessors read an observed `sequenceVersion`
  (bumped by `persistAndRefresh`) to re-derive in SwiftUI; the few views that read
  `hasPlaybackFiles`/`serviceFilterCounts` directly off a playlist read it too.

### Stage C — lazy identifier rendering in views

- **`AppState`** — the file-list accessors are `[PersistentIdentifier]`: `managerFileIDs`,
  `visualChannelFileIDs` (display sequence), `audioChannelFileIDs` (playback sequence). A
  `file(for:)` resolver wraps `modelContext.model(for:)` for the one row a caller needs.
  `currentVisualFile`/`currentAudioFile` resolve the playlist's `currentFileID` through a
  single-row `identifier(of:)` fetch and confirm membership in the (cheap) identifier
  sequence, rather than walking a materialized list. The selection-driven action paths
  (`playSelectedFile`, `requestDeleteSelectedFiles`, `moveFileSelection`, the context-menu
  targets) resolve only the small selection via `selectedManagerFiles()` and intersect it with
  the identifier sequence — the whole sequence is never materialized; `manage`/`switchScope`
  test the resume file's membership with `displaySequenceContains`.
- **`FileCollectionView` + `LibrarySurface` + the player/audio overlays** —
  `ForEach(ids, id: \.self)`; each realized row resolves `appState.file(for: id)` and skips
  `nil`. Selection and scroll stay UUID-keyed (`.id(file.id)`, `proxy.scrollTo(file.id)`);
  `FileSelection` keeps the anchor as a `PersistentIdentifier` and resolves only a shift-click's
  spanned range to UUIDs (plain/cmd clicks resolve nothing).

This stage is where the cold-start win is realized: the `LazyVStack`/`LazyVGrid` realize only
visible rows, so only those resolve a model, and the action paths resolve only the selection or
a single target.

## Documentation

- `doc/architecture.md` — update the data-model / persistence description to: tags as a
  normalized `Tag` relationship, `taggingStatus` stored as a scalar, sequences derived
  store-side as ordered identifiers with lazy row resolution. Describe the end state
  statically (no change-narration).
- `index.md` — mark Task 17 ✅ when built and tested; drop the interim note.

## Testable

- **Tags rebuild from filenames.** A scan/Update populates the `Tag` relationship from
  filenames; `tag(named:)` dedupes by normalized name and the unique constraint holds; filter
  and count results match the pre-refactor parse for the same filenames.
- **Sequence parity.** `displaySequence`/`playbackSequence` return the same order and
  membership as the pre-refactor results under no filter, each service filter, and tag
  AND/OR (port the cases in `PlaylistPlaybackTests`).
- **Counts.** `serviceFilterCounts` / `hasPlaybackFiles` match the per-file walk.
- **Save-before-derive.** A filter / tag edit / reshuffle, saved then re-derived, reflects
  the change; an unsaved mutation leaks no stale or pending row (the load-bearing
  `includePendingChanges: false` constraint).
- **Laziness.** A large playlist switch fetches identifiers and resolves only the visible
  rows — no full materialization.

Trap discipline (CLAUDE.md): hold the `ModelContainer` for the whole test body; for any
coordinator test use the window-free `AudioPlaybackEngine` with empty `Data()` files and
`defer { shutdown() }`.
