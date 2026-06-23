# Code review — Task 15 (Audio Overlay) + refactoring

Scope: `git diff main...HEAD` on `task-15-audio-overlay` (41 files, ~2090 insertions in app source). Reviewed for adherence to `doc/features.md`, the CLAUDE.md rules, and the iOS skills, plus naming and `doc/architecture.md` staleness. Tasks 16–20 (settings, lifecycle/position persistence, cloud, HDR, accessibility) are **not started**, so their absence is by design and is not flagged.

Findings carry status: tick the box when addressed.

The spec-compliance core is sound — the Esc priority chain, Key Context handoff, overlay exclusivity, per-playlist persisted service filter, the Skipped-filter Play guard (`hasPlaybackFiles`), and pause-vs-suppression all track `features.md`. The findings below are the real defects plus the cleanup/naming the diff warrants.

---

## Correctness

### C1 — `advance()` resumes playback while suppressed and persists `.playing` (HIGH)
- [x] `ShuTaPla/Engines/PlaybackCoordinator.swift:244,247` — **CONFIRMED & FIXED.** Reproduced red on the unchanged code: `advanceWhileSuppressedDoesNotFlipPausedToPlaying` (state flipped to `.playing`) and `advanceWhileSuppressedReSuspendsTheEngine` (`pauseCount` stayed 1, engine left audible). Both `.visualVideo`/`.audio` cases now route through `settleStateAfterAdvance(_:)` (sets `.playing` only when `!isSuppressed`, re-suspends if `!shouldBePlaying`); both tests green.

This diff adds `playlist.playbackState = .playing` to the `.visualVideo` and `.audio` cases of `advance(_:forward:)`, with no suppression guard. `jump()` is gated (`guard playlist.playbackState == .playing, !isSuppressed else { return false }`) but `advance()` is not, and `routePlayer` has no `isSuppressed` check before the arrow-key branch.

**Scenario:** Pause overlay up (`isSuppressed == true`). User presses `[arrow right]` → `routeVisual`/`routeAudio` → `coordinator.next()` → `advance()`: the engine's `advanceToNext()` loads and **auto-plays** the next file (audible audio, or video advancing behind the opaque overlay), and the persisted state flips to `.playing`. Suppression is silently broken, and because the state is now `.playing`, a later `unsuppress()` treats it as a resumed playlist — the corruption outlives the overlay.

**Fix:** route `advance()` through the same `shouldBePlaying`/`!isSuppressed` gate as `jump()`, or guard the transport keys in `routeVisual`/`routeAudio` while `coordinator.isSuppressed`.

### C2 — `confirmManagerDelete` doesn't reconcile the live channel → use-after-free on a deleted model (HIGH)
- [x] `ShuTaPla/State/AppState.swift:1025` (via `deleteFiles` at `:812`) — **CONFIRMED & FIXED.** Reproduced red on the unchanged code: `confirmManagerDeleteAdvancesTheLiveAudioChannel` (the live audio `currentFileID` stayed on the deleted track). `deleteFiles` now calls `reconcileChannels(for:)` after `rebuildTagFrequency`; test green.

`confirmManagerDelete` → `deleteFiles` runs `file.playlist = nil; modelContext.delete(file)` but never calls a reconcile, unlike `confirmAudioDelete` (`:1069`) and `confirmPlayerDelete` (`:1185`), which both reconcile after the delete.

**Scenario:** Manager mode, audio scope, an audio playlist playing on the parallel channel. User selects the currently-playing track and presses `[delete]` → `requestManagerDelete` → `confirmManagerDelete` → `deleteFiles`. The track's model is destroyed but the audio engine still holds it as `currentFile`. At natural EOF, `advanceToNext()` → coordinator `fileAfter(current)` dereferences `current.playlist` on a destroyed SwiftData model → trap (the orphaned/destroyed-model trap class from CLAUDE.md). There is a test for `confirmAudioDelete`'s reconcile but none for `confirmManagerDelete`.

**Fix:** after `deleteFiles`, reconcile whichever channel(s) reference the deleted file's playlist (or do it inside `deleteFiles`). Add a reproducing test.

### C3 — `apply(delta:)` reconciles only the audio channel after a re-scan prune, not the visual (MEDIUM-HIGH)
- [x] `ShuTaPla/State/AppState.swift:751` — **CONFIRMED & FIXED.** Reproduced red on the unchanged code: `rescanPruneAdvancesTheLiveVisualChannel` (the visual `currentFileID` stuck on the pruned file). `apply` now calls the symmetric `reconcileChannels(for:)`; test green.

`apply` ends with `if coordinator.audioPlaylist === playlist { coordinator.reconcileAudioSelection() }` and no visual analog, though the comment claims it advances off the dropped track "just like a delete does." A background re-scan (the automatic Update) that prunes the on-screen video/image file deletes the model but leaves the **visual** engine holding it.

**Scenario:** A video plays in Player mode; its file is removed on disk; the auto-update re-scan prunes it → `apply` deletes the model, reconciles audio only → next EOF advance dereferences the destroyed model. (Explicit deletes go through `confirmPlayerDelete`, which does reconcile visual — only the re-scan path is uncovered.)

**Fix:** add the symmetric `if coordinator.visualPlaylist === playlist { coordinator.reconcileVisualSelection() }`.

### C4 — Player `[delete]` ignores audio key context (MEDIUM)
- [x] `ShuTaPla/Engines/HotkeyRouter.swift:255` — **CONFIRMED & FIXED.** Reproduced red on the unchanged code: `deleteUnderAudioKeyContextTargetsTheAudioTrack` (`audioDeleteCandidate` stayed nil — the video was targeted). The `[delete]` branch now routes through key context to `requestDeletePlayingAudioFile()` when audio holds it; test green.

The `[delete]` branch runs **before** the audio/visual key-context split (`:259`) and always calls `requestDeletePlayingFile()`, which reads `coordinator.visualCurrentFile`. With the extended audio overlay focused (`audioHoldsKeyContext`), `[delete]` raises the trash confirmation for the **video**, not the focused audio track (whose only delete path is the overlay row menu). Every other contextual key (`space`/arrows/`l`/seek) respects key context; `[delete]` doesn't.

**Fix:** route `[delete]` through key context — when audio holds it, target `currentAudioFile` via `requestAudioDelete`.

### C5 — Audio `[space]` can't restart a stopped audio playlist (MEDIUM)
- [x] `ShuTaPla/Engines/HotkeyRouter.swift:306` — **CONFIRMED & FIXED.** Reproduced red on the unchanged code: `spaceRestartsAStoppedAudioChannel` (`[space]` returned false / channel stayed `.stopped`). `routeAudio` now handles `[space]` via `togglePlayback(audioChannelSlot ?? audioPlaylist)` ahead of the `guard let audioPlaylist`; test green.

`routeAudio`'s `[space]` uses `coordinator.togglePause(audio)` behind `guard let audio = coordinator.audioPlaylist`. After Stop, `stopAudio()` clears `audioPlaylist`, so the guard fails: `[space]` returns `false` (does nothing, and may ring the bell) even though `audioChannelSlot` survives and the on-screen Play button — which uses `togglePlayback` — *can* restart. The comment at `PlaybackCoordinator.swift:199-202` documents exactly this `togglePause`-can't-start gap.

**Fix:** route audio `[space]` to `togglePlayback(audioChannelSlot)` to mirror the transport button.

### C6 — `reconcileAudioSelection` leaves `audioPlaylist` set on an empty sequence (MEDIUM)
- [x] `ShuTaPla/Engines/PlaybackCoordinator.swift:379` — **FIXED** (behavior decided: stop the channel). The visual channel deliberately stays live-and-empty so the player can show a "no files" placeholder and the user can lift the filter from there; the audio channel has no such placeholder, so an emptied audio sequence now calls `stopAudio()` (clears `audioPlaylist`, sets `.stopped`) — easy to restart from the same overlay. Test `reconcileAudioStopsTheChannelWhenSequenceEmpties` updated to the new behavior: reproduced the old "stays live" state red first (`audioPlaylist` non-nil, `.playing`), then green after the fix. The visual analog (`reconcileClearsCurrentFileWhenSequenceEmpties`) is untouched and still passes.

On an empty `playbackSequence` it calls `audioEngine?.stop()` but does not clear `audioPlaylist` or the playlist state. `AudioTransport` then still reads as live (Prev/Stop/Next/Loop) with `audioCurrentFile == nil`; pressing Next advances over an empty sequence. The visual analog keeps the channel deliberately so the player can show a "no files" placeholder — but audio has no such placeholder, so the live-but-empty transport is just inconsistent.

**Scenario:** toggling the `.skipped` triage filter on the live audio playlist → `filterChanged` → `reconcileAudioSelection` → empty sequence → engine stopped, transport still claims live.

**Fix:** clear `audioPlaylist`/state when the audio sequence empties, or give the overlay an explicit empty state.

### C7 — Reconcile reads `.id` on a just-deleted model (LOW-MEDIUM)
- [x] `ShuTaPla/State/AppState.swift:1069,1185` — **REFUTED. No change made.** This was a hypothesis ("reading `.id` on a deleted-but-referenced model may return stale or trap"). Tested against the unchanged code: the four reconcile-after-delete tests (`confirmAudioDeleteAdvancesPastTheTrashedTrack`, `confirmManagerDeleteAdvancesTheLiveAudioChannel`, `rescanPruneAdvancesTheLiveVisualChannel`, plus the existing audio-rescan delete) all pass — reading `.id` on the just-deleted model neither traps nor returns a stale value that breaks the `sequence.contains` check; the advance lands on the correct next track. The defect doesn't reproduce, so the original reconcile-after-delete ordering is left in place (an exploratory read-engine-file reorder was reverted).

### C8 — `LibrarySurface` inline-rename `@State` not reset on in-place playlist switch (MEDIUM)
- [x] `ShuTaPla/Views/Shared/LibrarySurface.swift:54` — **FIXED** (view-state, not unit-reproducible). Added `.onChange(of: context.activePlaylist?.id)` that clears `fileRenamingID`/`fileDraftName`.

`fileRenamingID`/`fileDraftName` are `@State` on the shared surface. `context.onSelectPlaylist` swaps the active playlist without remounting the view (the list is swapped in place; `onAppear` doesn't refire), so an abandoned rename draft for file X persists across the switch and re-activates if X scrolls back into view.

**Fix:** reset the rename state on active-playlist-id change (`.onChange`) or `.id(playlist.id)` the surface.

### C9 — `currentAudioFile` (displaySequence) vs reconcile (playbackSequence) disagree under the Skipped filter (LOW)
- [x] `ShuTaPla/State/AppState.swift:256` — **FIXED.** `audioChannelFiles` now derives from `playbackSequence` (skipped tracks excluded), so the audio overlay — a transport list, not a triage surface — never shows a skipped track and `currentAudioFile` (which resolves within that list) never makes one current; under the Skipped filter the list is empty. `visualChannelFiles` stays `displaySequence` because the Files & Tags overlay is an editing surface where skipped rows are triaged/un-skipped (the asymmetry is now documented on both accessors). Test `audioOverlayHidesSkippedTracksAndNeverMakesOneCurrent`: reproduced red first (skipped track present and current), green after the fix.

`currentAudioFile` resolves against `audioChannelFiles` = `displaySequence`, which **includes** skipped files under the `.skipped` filter; `reconcileAudioSelection` uses `playbackSequence`, which never does. Under `.skipped` the overlay can highlight a "current" track the engine treats as unplayable.

---

## Efficiency

### E1 — `currentAudioFile`/`currentVisualFile` re-derive the whole `displaySequence` per render (MEDIUM)
- [x] `ShuTaPla/State/AppState.swift:256,266` — **FIXED** (the simple, self-contained part). Added list-aware overloads `currentAudioFile(in:)` / `currentVisualFile(in:)` that resolve the current file within an already-derived list; the zero-arg properties delegate to them (one resolution rule). `AudioOverlay.audioContext` and `FilesTagsOverlayView.visualContext` now derive their list once and pass it to the overload, dropping the redundant second O(n) walk in the expanded surface. Guarded by the existing `currentAudioFile*` tests plus a new `currentVisualFileResolvesFromTheLiveVisualPlaylist` baseline (run green before and after the refactor). The deeper "thread the list through the compact bar too" change is left to Task 17's view-layer pass.

Each accessor calls `audioChannelFiles`/`visualChannelFiles` (a full `displaySequence` walk + sort) just to look up one file by id. The overlays read both the list **and** the current file in the same body, so each render does two full O(n) derivations; the body re-evaluates on every `audioCurrentTime`/`visualCurrentTime` scrubber tick during playback. This is a new double-walk the diff introduces, compounding the known single-walk cost that Task 17 addresses.

**Fix:** look the current file up *within* the already-derived list (pass it in, or derive once in the context), instead of re-deriving inside `currentAudioFile`/`currentVisualFile`.

---

## Cleanup / duplication / altitude

### D1 — Audio and player delete flows are near-duplicates (HIGH cost)
- [ ] `ShuTaPla/State/AppState.swift:1048-1188`

`requestAudioDelete`/`cancelAudioDelete`/`confirmAudioDelete` mirror `requestPlayerDelete`/`cancelPlayerDelete`/`confirmPlayerDelete`, each with its own candidate/error pair, differing only in which reconcile they call. Two confirmation state machines (and the candidate-pruning in `apply` already special-cases both `audioDeleteCandidate` and `playerDeleteCandidate`) must move in lockstep forever. Parameterize one delete-then-reconcile flow on the channel.

### D2 — `reconcileAudioSelection` clones `reconcileVisualSelection` (HIGH cost)
- [ ] `ShuTaPla/Engines/PlaybackCoordinator.swift:350-381`

Line-for-line the same guard, `playbackSequence` walk, and jump-to-first/clear, differing only in `audioPlaylist`/`audioCurrentFile` vs the visual fields — and the audio copy already dropped the visual one's placeholder nuance (see C6). Fold into one `reconcile(_ channel:)` parameterized on the channel's playlist + current file + stop.

### D3 — `selectVisualPlaylistInPlayer` and `selectAudioPlaylist` duplicate the play-on-select pattern (MEDIUM)
- [ ] `ShuTaPla/State/AppState.swift:~580`

Both compute `isNewSelection`, load/remember, conditionally `coordinator.play`, bump a scroll token, and respawn `updateTask`. The visual variant delegates to `select()`; the audio variant re-inlines part of it (its own `audioScrollToken`, no `managerSelection` seeding), so the two can drift.

### D4 — `AudioInlet` hand-rolls a drag-seek bar that `AudioOverlay` expresses with a `Slider` (MEDIUM)
- [ ] `ShuTaPla/Views/AudioInlet.swift:~158`

`AudioInlet` builds `GeometryReader` + capsules + `DragGesture` + `progressFraction` for the same seek-on-the-audio-channel interaction that `AudioOverlay`'s scrubber gets from a `Slider` bound to `audioCurrentTime`/`audioDuration`. Two widgets for one channel — the fraction↔seconds mapping, the `duration <= 0` guard, and the clamping are written twice. Extract one seek-bar view.

### D5 — `select()` and `selectAudioPlaylist` share one `updateTask` field → cross-channel re-scan cancellation (LOW)
- [ ] `ShuTaPla/State/AppState.swift:~561`

Both store their background re-scan in the single `updateTask` and cancel the prior one. Selecting an audio playlist in the overlay while a Manager visual re-scan is in flight cancels the visual re-scan; on-disk changes for the just-selected visual playlist aren't picked up until it's re-selected. Consider per-channel task slots.

---

## Naming (the diff's identifiers are inconsistent across layers — the user asked for improvement ideas)

### N1 — The managed-select verbs are an opaque thicket (HIGH)
- [ ] `select` / `selectVisualPlaylistInPlayer` / `selectAudioPlaylist` / `beginPlayback` / `beginManagerPlayback` (AppState) + `coordinator.playNow`

Nothing in the names says which start playback or which channel/slot they touch. Suggest spec-aligned verbs: `manage(_:)` (loads the Managed Playlist, no playback) vs `playInPlayer(_:)` / `playOnAudioChannel(_:)` for the overlay play-on-select variants, and `beginPlayback` → `enterPlayer(_:startingAt:)`.

### N2 — `togglePause` vs `togglePlayback` give no hint of the difference (MEDIUM)
- [ ] `ShuTaPla/Engines/PlaybackCoordinator.swift:195,203`

`togglePause` is a dead end on a Stopped playlist; `togglePlayback` additionally starts one. A caller wiring a Play button to `togglePause` silently no-ops after Stop (this is C5). Suggest `togglePauseIfActive` / `playOrTogglePause`, or collapse to one method.

### N3 — Slot/channel words diverge from each other and from the spec (MEDIUM)
- [ ] AppState `managedPlaylist`/`audioChannelSlot`/`lastActiveVideoPlaylist` vs coordinator `visualPlaylist`/`audioPlaylist`

`audioChannelSlot` (AppState, the persistent slot) and `audioPlaylist` (coordinator, the live one) name the same conceptual Audio Channel Playlist with different words and lifetimes — easy to conflate. Adopt one convention (e.g. coordinator `liveVisualPlaylist`/`liveAudioPlaylist`, AppState `audioChannelPlaylist`) so identifiers map onto the terminology table's "Visual/Audio Channel Playlist."

### N4 — Key Context is split across two names; the terminology table lists only one (MEDIUM)
- [ ] `OverlayManager.audioFullyRevealed` (flag) + `audioHoldsKeyContext` (predicate)

The spec's single "Key Context" concept is realized as a backing flag plus the predicate callers actually read; `doc/tasks/index.md` line 25 maps only `audioFullyRevealed`. Consider one `keyContext` accessor (returning `.visual`/`.audio`) and update the table.

### N5 — `loadManaged` / `remember` / `switchScope` overlap and hide a side effect (MEDIUM)
- [ ] `ShuTaPla/State/AppState.swift:~354`

Three verbs for "make this the managed playlist / pick the scope," and `loadManaged` quietly also mutates `managerScope`. Suggest `rememberLastManaged(_:)` and `setManaged(_:)` with the scope effect named in a doc line.

---

## UI / HIG

### U1 — Scope-tab SF Symbol fill is inverted (MEDIUM)
- [x] `ShuTaPla/Views/ManagerSplitScene.swift:432` — **FIXED** (cosmetic). Now `isActive ? "\(systemImage).fill" : systemImage` (active scope filled).

`Image(systemName: isActive ? systemImage : "\(systemImage).fill")` — the **active** scope renders the outline glyph while inactive scopes render `.fill`, backwards from the platform's selected=filled convention (per `mobile-ios-design`/HIG). The gray capsule is the only correct active cue; the glyph contradicts it. Swap the ternary.

### U2 — Strip-audio spinner never shows in the visual overlay (MEDIUM)
- [x] `ShuTaPla/Views/Shared/LibrarySurface.swift:191` — **FIXED** (cosmetic). Now passes `isStripping: appState.strippingFileIDs.contains(file.id)`.

`FileRowView(..., isStripping: false, ...)` is hardcoded, while `FileCollectionView` passes `appState.strippingFileIDs.contains(file.id)`. The visual Files & Tags overlay wires `onRemoveAudio`, so a video row can start a strip there but gets no progress feedback (Manager shows it correctly). Pass `appState.strippingFileIDs.contains(file.id)`.

---

## Documentation

### DOC1 — `architecture.md` §4 state-object diagram is stale (HIGH)
- [x] `doc/architecture.md:159,167-169` — **FIXED.** §4 diagram rewritten with the real fields (AppStateModel: `lastActiveVideoPlaylistId`/`lastActiveImagePlaylistId`/`audioChannelPlaylistId`/`managerScopeRaw`; PlaybackCoord: `videoEngine`/`imageEngine`/`audioEngine` + visual/audio playlist + `isSuppressed`; OverlayMgr: `active: Set<Overlay>` + `audioFullyRevealed`/`audioCompactPinned`).

The §4 ASCII diagram still shows:
- AppStateModel box: `active playlist IDs` — §3 (updated) now lists `lastActiveVideoPlaylistId` / `lastActiveImagePlaylistId` / `audioChannelPlaylistId` / `managerScopeRaw`.
- `PlaybackCoord.` box: `videoPlayer` / `audioPlayer` / `imageTimer` — the coordinator owns `videoEngine` / `imageEngine` / `audioEngine`.
- `OverlayMgr` box: `filesTagsOpen` / `audioState` / `playlistsOpen` / `pauseShown` — the manager holds a flat `active: Set<Overlay>` plus `audioFullyRevealed` / `audioCompactPinned`. **`playlistsOpen` names the deleted `PlaylistsOverlay`/`.playlistsSidebar`.**

The §3 data-model, §6 UI sections, and the `Overlay` enum elsewhere in the doc were updated and are accurate — only this one diagram lags. (The forward-looking design for unbuilt tasks — `CloudFileService`, file-position persistence — is intentional design, not staleness.)

### DOC2 — `ScopeTabs` doc comment describes a two-tab design (residue) (MEDIUM)
- [x] `ShuTaPla/Views/ManagerSplitScene.swift:387` — **FIXED.** Comment now reads "the Image, Video, and Audio tabs."

The comment says "the Visual and Audio tabs in a single toolbar item," but the body renders three tabs — Image, Video, Audio (`ManagerScope` has separate `.image`/`.video`). It misdescribes the scope model and violates CLAUDE.md's describe-the-code-as-it-is rule. Update to three tabs.

---

## Checked and found clean

- **Channel routing through `LibraryContext`** (the wrapper shared by `AudioOverlay` and `FilesTagsOverlayView`): audio context routes to audio slots/actions, visual to visual — no cross-channel mis-wiring found.
- **Deleted-symbol fallout**: no surviving references to `PlaylistsOverlay`, `.playlistsSidebar`, or the other removed/renamed symbols in source or tests; `ControlButtonStyle` was correctly promoted to a shared non-private file.
- **Test trap classes** (CLAUDE.md): engine-backed tests use the window-free `AudioPlaybackEngine` with empty placeholder files and `defer { shutdown() }`; no new trap-class violations.
- **Spec behavior**: Skipped-filter hides the Manager Play button and disables the Audio Inlet Play; Esc chain, Key Context handoff, overlay exclusivity, and service-filter honoring across surfaces all match `features.md`.
- **Change-narration/residue** in new code comments: the `no longer` hits describe runtime state (a file no longer in a playlist), not history — except DOC2.
