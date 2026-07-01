# AppState modularization & simplification

`ShuTaPla/State/AppState.swift` has grown to ~1670 lines across many features, accreting
functions and computed properties that were rarely consolidated. This task relocates logic to
its natural owners, extracts one cohesive collaborator, folds in the safe simplifications, and
only then splits the irreducible orchestrator core across extension files.

Steps are ordered and implemented **one at a time, test-first**: for each step, cover the
behavior first (existing `AppStateTests` covers much; add reproducing coverage where thin), run
it green on the current code, make the move, and confirm the suite stays green + the issue
navigator stays clean before moving on.

## Guiding principles

- **Relocate before splitting.** `extension AppState` files are the last resort, for what's
  genuinely left after logic finds a better home (the model, the error type, a collaborator).
- **Mind naming and established terminology.** New names must hint at what they do and use the
  glossary vocabulary (`doc/features.md#terminology`): Managed Playlist, Visual/Audio Channel,
  Scope, Service Filter, Saved Search, Filter Bar.
- **Model concerns live on the model.** `Playlist` already has `Models/Playlist/Playlist+<Concern>.swift`
  extensions (`+Sequence`, `+ResumeSlot`, `+Preferences`); pure filter/saved-search logic joins them.
- **The split's cost:** Swift `private`/`fileprivate` are file-scoped, so moving callers into
  sibling extension files forces a few shared helpers from `private` to `internal`. Keep a thin
  core in `AppState.swift` (state, `init`, cross-cutting persist/fetch plumbing) so those stay
  `private`; widen only what a sibling must reach.

---

## Step 1 — `FileSystemError.userMessage` (Tier 1a) ✅

Pure `error → user copy` mapping; the error type is the owner.

**Moves**
- `AppState.message(for: FileSystemError)` → `var userMessage: String` on `FileSystemError`
  (in `Services/FileSystemService.swift`, beside the enum).
- `applyRename`'s `catch let error as FileSystemError` returns `error.userMessage`.
- Delete `message(for:)` from AppState.

**Tests**
- `FileSystemError.userMessage` returns the expected string for each case (pure, no isolation).
- Existing rename-failure tests still pass.

**Done:** no other `message(for:)` references; navigator clean.

---

## Step 2 — Fold folder access into `ScopedFolderAccess` (Tier 2c) ✅

`ScopedFolderAccess` (`Engines/`) already serves playback: persistent, id-keyed, ref-counted
sessions (`begin`/`end`/`url(for:)`/`releaseAll`). AppState's trio is the other lifecycle — a
**one-shot** scoped session for a single mutation, with an **interactive re-grant** when the
bookmark is stale. Both become one service.

**The two-lifecycle trap:** the one-shot path must NOT reuse the keyed map. If a playlist is
playing (coordinator holds its keyed session) and the user edits a file in it, a keyed `begin`
would return the URL without a fresh `startAccess`, and the op's release would `stopAccess` and
evict the entry — killing the live session. The one-shot path does its own `startAccess`/
`stopAccess` (safe alongside a playback session; `BookmarkService` is reference-counted).

**The prompt seam — the UI panel is its own thing, not part of the service.**
- New `FolderReaccessPrompting` protocol: `func requestAccess(to playlist: Playlist) -> URL?`
  (mirrors the existing `FileSystemProviding` seam).
- New `FolderReaccessPanel` — the sole `import AppKit`, owns the `NSOpenPanel` re-grant. Its own file.
- `ScopedFolderAccess` stays Foundation-only and takes `prompt: FolderReaccessPrompting` at init;
  production wires the panel, tests wire a stub (canned URL, or `nil` for the cancel path).

**Service additions to `ScopedFolderAccess`**
- `func withAccess<T>(to playlist: Playlist, perform body: (URL) async -> T) async -> T?` —
  one-shot: try `startAccess`; on failure `prompt.requestAccess` → refresh bookmark → retry;
  run `body`; `stopAccess` in `defer`. Returns `nil` when access can't be obtained. (Note the
  double-optional at call sites where `T` is itself optional, e.g. an error `String?`: flatten
  with `?? nil`.)
- `@discardableResult func refreshStaleBookmark(for playlist: Playlist) -> Bool` — proactive, no
  prompt (the rescan path); plus the private `refreshBookmark(of:from:)` helper. The service
  mutates `playlist.folderBookmark` in memory; the caller still owns the `save`.

**Rewiring (restructure freely — no defensive defaults)**
- AppState builds `FolderReaccessPanel` + `ScopedFolderAccess(bookmarkService:prompt:)`, holds
  `folderAccess`, and injects it into `PlaybackCoordinator.init` (which drops its internal
  construction; required parameter). Update the coordinator's call sites and its tests to pass a
  `ScopedFolderAccess` with a stub prompt.
- AppState file-edit methods (`renameFile`, `deleteFiles`, `stripAudio`, `editTags`,
  `revealInFinder`) switch from `beginFolderAccess` + `defer { stopAccess }` to
  `folderAccess.withAccess(to:) { url in … }`. `update`'s stale-bookmark refresh →
  `folderAccess.refreshStaleBookmark(for:)`.
- Delete `beginFolderAccess`, `refreshBookmark`, `promptForFolderAccess`, `refreshStaleBookmark`
  from AppState.

**Tests**
- `withAccess`: runs `body` with the URL when access granted; re-prompts and refreshes the
  bookmark when the initial access is stale (stub prompt returns a URL); returns `nil` when the
  prompt cancels. Back with an in-memory container (hold it for the whole body — orphaned-context
  trap); no libmpv touched.
- Existing rename/delete/strip/tag file-op tests still pass through the new path.

**Done:** folder-access helpers gone from AppState; coordinator constructs cleanly with the shared
service; navigator clean.

---

## Step 3 — Filter & saved-search logic onto `FilterState`/`Playlist` (Tier 1b) ✅

The Filtering and tag-rewrite clusters are mostly pure value-type edits sitting on AppState. Move
the pure transitions to the model; AppState keeps only the orchestration (`filterChanged` and its
`restoreTarget`/`reseedManagerSelection` side effects: persist → coordinator jump → re-center).

**Onto `FilterState`** (mutating methods; `FilterState` is a `nonisolated struct` — trivially
unit-testable with no `@MainActor`/`ModelContext`):
- `toggle(tag:)` — clears the service filter, adds/removes by `TagParser.sameTag`.
- `toggle(service:)` — set/unset the mutually-exclusive triage filter.
- `clearTags()`.
- (Setting the AND/OR mode stays a plain `filterMode =`.)

**Onto `Playlist`** (new `Models/Playlist/Playlist+Filtering.swift`, `@MainActor extension`; touches
both `filterState` and `savedSearches`):
- `saveCurrentSearch()`, `applySavedSearch(_:)`, `removeSavedSearch(_:)`, `promoteSearch(_:)`.
- `rewriteFilterTag(_ transform:)` (the tag-rename rewrite) and `dropFilterTag(_:)` (the
  playlist-wide removal rewrite, discarding a search left with ≤1 tag).
- `clearResumePositions()` (on `Playlist+ResumeSlot`) — the resume-slot reset `reshuffle` does.

**Stays on AppState** (thin wrappers: edit the model, then `filterChanged`): `toggleServiceFilter`,
`toggleFilterTag`, `setFilterMode`, `clearTagFilter`, `saveCurrentSearch`, `applySavedSearch`,
`removeSavedSearch`; `renameTagAcrossPlaylist`/`removeTagAcrossPlaylist` call the model rewrite/drop.
`reshuffle` calls `playlist.clearResumePositions()`.

**Tests**
- Pure `FilterState` unit tests (no isolation): toggle add/remove/dedup, service-filter exclusivity,
  clear-clears-service-on-tag-edit.
- `Playlist` saved-search tests: promote de-dup keeps the existing search's `resumeSortOrder`;
  `rewriteFilterTag` maps active + saved; `dropFilterTag` discards a ≤1-tag search, rewrites a
  larger one, leaves an unaffected one.
- Existing AppState filter tests still pass through the wrappers.

**Done:** filter/saved-search pure logic lives on the model; AppState holds only orchestration.

---

## Step 4 — Tier-3 consolidations ✅

**Delete `ManagerScope`** — verified 1:1 with `MediaType` (`String` raw values `video`/`image`/
`audio`). Replace `managerScope: ManagerScope` with `MediaType`; `switchScope(to: MediaType)`;
drop `ManagerScope(_:)`/`.mediaType`/`init?(rawValue:)`; `resolveActivePlaylists` uses
`MediaType(rawValue:)`; `setManaged` uses `playlist.mediaType`. Update `ManagerSplitScene.swift`
(one property + two `switchScope` calls) and the `AppStateModel.managerScopeRaw` doc comment
(`managerScopeRaw` stays a `String`).

**Keyed remembered-playlist accessor** — collapse the per-type triple. `rememberLastManaged`,
`lastManagedPlaylist(for:)`, and `delete`'s 12-line clearing block each switch over the same three
cases. Introduce `rememberedPlaylist(for: MediaType) -> Playlist?` (get) and `remember(_ playlist:)`
(set), each reading/writing both the in-memory ref and its `AppStateModel` id in one place. The
in-memory refs stay stored on AppState (Observation); the switch collapses into the accessor and
`delete`'s block becomes a single keyed clear.

**Tests:** existing scope-switch / remember / delete tests stay green; add a `MediaType`-parameterized
round-trip for `remember`/`rememberedPlaylist` if coverage is thin.

**Done:** `ManagerScope` gone; the three switch statements are one accessor; navigator clean.

---

## Step 5 — Split the orchestrator core across extension files ✅

With the above done, the residue is genuine main-actor orchestration needing the shared observable
state. Split behavior-preservingly into a `State/AppState/` folder (mirroring `Models/Playlist/`).
Because Swift stored properties can't live in extensions and `private` is file-scoped, the core
`AppState.swift` holds *all* stored properties + `init`; a helper/state member widens from
`private`/`private(set)` to internal only where a sibling reaches it (each such member is set only
by this type's own methods — noted in the core file's header).

- `AppState.swift` — class decl, all stored properties, `init`, and the cross-cutting persist/fetch
  core (`persistAndRefresh`, `file(for:)`, `selectedManagerFiles`, `managerSelectionFiles`,
  `displaySequenceContains`).
- `AppStateTypes.swift` — `AppMode`, `MoveDirection`, `PendingPlaylist` (+ext), `ImportingPlaylist`,
  `AddPlaylistOutcome`.
- `AppState+Slots.swift` — slot/scope references, launch resume (`resolveActivePlaylists`,
  `reconstructPlayback`), `switchScope`, `setManaged`, remembered-playlist accessor.
- `AppState+Lifecycle.swift` — window close/reopen/terminate + window frame.
- `AppState+Creation.swift` — add-folder → scan → `makePlaylist` flow.
- `AppState+Rescan.swift` — `manage`/`playOnVisualChannel`/`playOnAudioChannel`, the background
  update/reconcile path, `rename`, `delete`, `reorder`, `cancelInProgressOperation`.
- `AppState+FileOps.swift` — rename/delete/strip-audio/reshuffle/reveal + the tag edits (they share
  the disk-rename core `applyRename`/`editTags`).
- `AppState+Playback.swift` — `startPlayback` family, the Manager center + channel-derived id lists,
  current-file resolution, `stopAndExitPlayer`, grid navigation.
- `AppState+Confirmations.swift` — the request/cancel/confirm cluster (unchanged this pass).
- `AppState+Filtering.swift` — the filter/saved-search orchestration wrappers + `filterChanged`,
  `restoreTarget`, `reseedManagerSelection`.

**Done:** whole suite green (the vp8/vp9 duration flake aside, which passes in isolation); navigator
clean; no file materially oversized; conventions/writing-rules hold.

---

## Deferred (separate follow-up)

**Confirmation-cluster unification.** The `request/cancel/confirm` triples (Manager / Player / audio
delete, strip, tag) and `applyScanResult`'s four-way candidate pruning share one pending-confirmation
shape. Deferred because it couples to the `HotkeyRouter`/`.alert` blocking-modal rule
(`CLAUDE.md`) and the payoff is smaller — worth its own task so this pass lands clean.
