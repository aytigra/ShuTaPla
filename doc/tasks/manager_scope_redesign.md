# Manager Scope Redesign — managed playlist, per-type sidebar, channel-pinned overlays

One redesign with a single direction: the Manager manages **one playlist at a
time** generically, media type is a sidebar/UI distinction rather than a parallel
state split, and the player overlays are simplified, channel-pinned views of that
same machinery. This grounds the change in the code as it stands so the
implementation isn't guesswork; it is a direction + plan, not a line-level spec.

## The model

- **Manager manages one playlist** — the *managed-playlist slot*. The whole
  Manager view binds to it: the playlists sidebar, the center file list, the
  filter bar, and the tag inspector. The view adapts to the managed playlist's
  type (hide strip-audio for audio, no duration for images) and orchestrates the
  type's side effects (which channel a Play starts, how an action touches the
  audio transport).
- **Scope (image / video / audio) is only the sidebar's playlist-list type
  filter.** It decides which playlists you can pick from to become the managed
  one. It is not selection state, not filter state, not a routing key.
- **Two playback channels run in parallel**, each holding and overlay-managing one
  playlist:
  - **visual channel** — one video *or* image playlist (mutually exclusive)
  - **audio channel** — one audio playlist (independent; plays under the visual)

### Three slots, kept consistent by explicit loads — never the same object

| Slot | Owns | Lifetime |
|------|------|----------|
| managed-playlist | the Manager view | one at a time, any type |
| visual-channel | the visual player + its overlay | transient |
| audio-channel (`activeAudioPlaylist`) | the audio transport + its overlay | persistent |

The slots stay **separate references**, synced by explicit load steps — so no
surface reaches *through* into another's state (the coupling we're avoiding).
They often point at the same `Playlist` instance when in sync, which is fine; a
`Playlist` carries its own persisted `filterState`, so editing it from either
surface edits the one persisted filter.

### Sync rules

- **App start:** load the persisted managed playlist; set scope to its type.
- **Visual channel is transient:** stopping it *ejects* its playlist into the
  managed slot, and scope auto-switches to that playlist's type (image/video).
- **Audio channel is persistent:** stopping leaves the playlist loaded in the
  channel. The audio channel always holds one once it has had one (until that
  playlist is deleted, or none ever existed).
- **managed-audio ↔ audio-channel are synced both ways, never divergent:**
  selecting an audio playlist in Manager loads it into the audio channel (stopped,
  replacing and stopping the previous); switching to audio scope loads the
  audio-channel playlist into the managed slot. "Manage audio A while the
  transport plays audio B" never happens.
- **Sidebar scope is browsable but slaved to the managed type.** It's driven by
  the current scope so you can switch scope to browse a type's playlists even when
  none of that type are loaded. It auto-resyncs to the managed playlist's type on
  load events (app start, visual stop). A deliberate user scope switch is the
  browse gesture; selecting a playlist from the browsed list makes it managed, and
  the scope already matches it (so the managed→scope sync is a no-op there).

## Derived state, not synced state (governing principle)

The filter (`filterState`) and current file (`currentFileID`) are encapsulated,
persistent state on the `Playlist` model. The filtered, display-ordered file list
and the current-file highlight are *pure derivations* of that model — so the
correct shape is **edit the model, let every surface that reads it re-derive**,
not "mutate, then imperatively recompute a cached list and reconcile each
surface." SwiftData `@Model` is observable; a view reading `playlist.filterState`
(or a list derived from it) updates on its own.

This subsumes the "one managed state set" goal: the cached `filteredFiles` /
`audioFilteredFiles` + `recompute*()` + scroll-token machinery works *around* the
model rather than *from* it. Deriving also explains the slot model — two slots
pointing at the **same `Playlist` instance** are consistent for free, with no
content-sync code; the only thing ever synced is *which* playlist a slot
references, never its derived contents.

The **service filter joins `filterState`** as persisted, per-playlist model state,
applied uniformly — Manager, overlays, and playback all honor it. Looping the
untagged or invalid-tagged set to fix them is a feature, and remembering it across
launches lets triage resume. So it derives from the model exactly like the tag
filter: the runtime `activeServiceFilter` and its scattered `= nil`-on-switch
resets are gone, and per-playlist storage makes "doesn't carry across playlists"
automatic. Its toggling UI (the center's counter notices) stays in Manager. One
edge: the `skipped` filter selects non-playable files, so the *playable* sequence
is empty under it — a triage-only state. Guard the Play affordances to match: hide
the Manager Play button and make the audio inlet's Play a no-op while the active
filter is `skipped`.

With that, two things genuinely do **not** reduce to derivation and stay explicit
— they are the derivation boundary:

1. **The live engine is a side effect.** When a filter edit removes the file the
   engine is currently playing, the engine must be told to move to a matching file
   — external state that can't be derived. So "reconcile" shrinks to: *if this
   playlist is on a live channel and its playing file fell out of the filter,
   advance the engine.* In Manager that applies only to the audio channel (the
   visual channel is stopped while browsing); the overlays are always live.
2. **Engine position is the source of truth while playing.** The truly-current
   file of a live channel is the engine's, which can lead the persisted
   `currentFileID` until written back — so a surface showing the *playing* channel
   reads the engine, and everything else (browse, stopped, sidebar) reads the
   model. This is the existing `coordinator.visualCurrentFile` vs
   `currentVisualFile` split.

## Manager view vs. player overlays

- **Manager view** is the full surface: scope-driven playlists sidebar, center
  file list with **list + gallery (thumbnails)** and **multi-selection**, counter
  notices, **service filters**, plus the filter bar and tag inspector.
- **Player overlays are simplified Managers**, each pinned to one channel slot
  (visual overlay → visual-channel, audio overlay → audio-channel). Simplified
  means: **no service-filter toggles, no thumbnails/gallery, no multi-selection.**
  (They still *honor* a service filter set in Manager — it's model state — they
  just don't carry the counter-notice toggles.) The file list highlights the
  current track and **double-click jumps/plays**; the row context menu still offers
  rename / delete / etc. The tag editor targets the current file only.
- Structurally the overlays already render from the shared `LibrarySurface`
  (`Views/Shared/LibrarySurface.swift`), whose rows (`FileRowView`) have no
  thumbnail and highlight only the current track — so the overlay simplifications
  are largely already in place. An active service filter shows its "Showing
  untagged — clear" banner in the overlay too (the existing `FilterBar` banner,
  rendered straight from the model), so it stays visible and clearable there even
  though the overlay carries no counter-notice toggles.

## Filter routing (`FilterScope`, `FilterBar.swift`)

Each bar mutates its target playlist's persisted `filterState` (tag filter and
service filter alike); surfaces re-derive (governing principle). With service
filters now part of the model and applied uniformly, the three cases differ only
by *which playlist* the bar targets — so this is really just playlist selection,
and `FilterScope` could collapse to passing the target playlist:

| Scope | Surface | Playlist it edits |
|-------|---------|-------------------|
| `.manager` | Manager view (filter bar) | the managed playlist |
| `.visual` | Files & Tags overlay | visual-channel slot |
| `.audio` | Audio overlay | audio-channel slot |

`LibrarySurface` targets the overlay's channel playlist; `TagSidebar` targets the
managed playlist. The only explicit effect of an edit is the live-channel
reconcile (boundary item 1): it fires on any edit to a playlist that is currently
playing — always for the overlays, in Manager only when the managed playlist is
the live audio one.

## Implementation plan (delta from today, with code anchors)

1. **Scope becomes image / video / audio.** `ManagerScope`
   (`AppState.swift:32`) `.visual` splits into `.image` / `.video`. The sidebar
   sections (`PlaylistSidebar.swift`) show the one active type; `ScopeTabButton`
   (`ManagerSplitScene.swift:405`) gains a third tab.
2. **Derive instead of caching parallel sets.** Today the scope accessors
   (`managerPlaylist` / `managerFiles` / `managerSelection` / `managerFilterMode`,
   `AppState.swift:~356`–460) route over parallel cached pairs kept in sync by
   `recompute*()`: `filteredFiles` ↔ `audioFilteredFiles`, `selectedFileIDs` ↔
   `audioSelectedFileIDs`, `filterMode` ↔ `audioFilterMode`, `scrollSelectionToken`
   ↔ `audioScrollToken`. Per the governing principle, derive the filtered list from
   the managed `Playlist` (including its persisted service filter) rather than
   maintaining a cached managed copy; the audio channel's playback list derives
   from `activeAudioPlaylist` the same way, so the overlay and transport keep
   working while a video plays. Selection is one managed set (the scroll token
   stays as a deliberate "re-center now" event, not a derived value).
3. **Converge the select paths.** `select(_:)` (`AppState.swift:625`, visual
   Manager select) and `selectAudioInManager(_:)` (`AppState.swift:679`, audio
   Manager select — already browse/stopped and stops the previous live audio)
   become one managed-select that loads into the managed slot and, for audio, into
   the audio channel. The overlays keep their play-on-select variants
   (`selectVisualPlaylistInPlayer` `:653`, `selectAudioPlaylist` `:663`).
4. **Managed-playlist persistence + scope auto-sync.** The persisted active IDs
   already exist (`AppStateModel.activeVideoPlaylistId` / `activeImagePlaylistId`
   / `activeAudioPlaylistId`, maintained by `activate(_:)` at `AppState.swift:329`).
   Add: on launch and on visual stop, set scope to the loaded managed playlist's
   type; on a user scope switch, reselect that scope's slot as managed.
5. **Channel-pinned overlay targeting.** Point each overlay's filter bar at its
   channel playlist directly instead of borrowing `managerScope` (today
   `FilesTagsOverlayView` routes through `.manager`). With service filters in the
   model this is pure playlist selection, so `FilterScope` can stay a thin label
   or collapse to the target playlist. `FilterBar` lives in `FilterBar.swift`;
   `LibrarySurface` supplies the overlay's target.
6. **Persist the service filter.** Make `ServiceFilter` `Codable`, add it to the
   `filterState` struct, and apply it inside `computeFilteredFiles`
   unconditionally (drop the `applyingServiceFilter:` parameter). Remove the
   runtime `activeServiceFilter` and its `= nil` resets (`AppState.swift:109`,
   `:629`, `:1085`, and the `beginPlayback` reset); the center's counter notices
   toggle `playlist.filterState`'s service filter instead. Guard Play on a
   `skipped` filter: hide the Manager Play button and no-op the audio inlet's Play,
   since the playable sequence is empty.

## Reference points (at time of writing)

- `ManagerScope`: `AppState.swift:32`. Channel slots: `activeAudioPlaylist`
  `:119`, `selectedPlaylist` `:123`. `activate(_:)`: `:329`.
- Scope routing accessors: `AppState.swift:~356`–460; `managerScope` `didSet`
  (drops service filter, recomputes both lists): `:103`.
- Select paths: `select` `:625`, `selectVisualPlaylistInPlayer` `:653`,
  `selectAudioPlaylist` `:663`, `selectAudioInManager` `:679`.
- Recompute: `recomputeFilteredFiles` / `recomputeAudioFilteredFiles`
  (`AppState.swift:~1551`, `:1565`).
- Persisted active IDs: `AppStateModel` (`Models/AppStateModel.swift`).
- Sidebar sections / scope branching: `PlaylistSidebar.swift:54`–67, `135`, `171`;
  `ScopeTabButton`: `ManagerSplitScene.swift:405`.
- Filter routing: `FilterBar.swift` (`FilterScope`, `FilterBar`); overlays:
  `Views/Shared/LibrarySurface.swift`, `FilesTagsOverlayView.swift`,
  `Audio/AudioOverlay.swift`. Center file list: `PlaylistCenterView.swift`,
  `FileListView.swift` (multi-select), `FileGalleryView.swift` (thumbnails, visual
  only), `FileRowView.swift` (no thumbnail, shared by the overlays).
