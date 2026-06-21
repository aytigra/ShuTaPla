# Manager Scope Redesign — per-type sidebar + generic managed playlist

Two related Manager-mode changes. They can land independently of each
other, but they share a direction: the Manager center is generic over "the
playlist currently in management," and media type is a sidebar/UI distinction
rather than a parallel state split.

## #1 — Sidebar scopes: image / video / audio

Replace the two-way **visual / audio** scope with a three-way
**image / video / audio** scope, and remember the last-selected playlist per
scope so switching scope reselects it.

### Settled

- Three scopes, one media type each. The sidebar lists that scope's playlists.
- Switching scope reselects that scope's **last-managed playlist** (new
  per-type memory), so the center panel follows the scope.
- No cross-type switching is needed anywhere — each scope is its own type.
- Video and image still share one exclusive *playback* channel (`activate(_:)`
  nils the other); that exclusivity is a coordinator concern and is unchanged.
  The new per-type "last managed" memory is a *browse* slot, independent of the
  active playback channel.

### Shape

- `ManagerScope` becomes `.image | .video | .audio` (replacing `.visual`).
  Today: `AppState.swift:32`.
- `PlaylistSidebar.sections` (`PlaylistSidebar.swift:59`) shows one section for
  the active scope instead of Video+Image under `.visual`.
- `ScopeTabButton` (`ManagerSplitScene.swift:405`) gains a third tab.
- Per-type last-managed memory: a slot per scope (`lastImagePlaylistId`,
  `lastVideoPlaylistId`, `lastAudioPlaylistId`, or one `[MediaType: UUID]`),
  persisted on `AppStateModel`, set when a playlist is selected in that scope,
  read on scope switch to reselect.

## #2 — Generic managed playlist (collapse the visual/audio Manager split)

Today the Manager routes through `managerPlaylist` / `managerFiles` /
`managerSelection` / `managerFilterMode` (`AppState.swift:337`–423), branching
`.visual` vs `.audio` over **parallel** state: `filteredFiles` vs
`audioFilteredFiles`, `selectedFileIDs` vs `audioSelectedFileIDs`, `filterMode`
vs `audioFilterMode`, `scrollSelectionToken` vs `audioScrollToken`.

The Manager center, filter bar, and tag inspector are generic over the managed
playlist — the type only changes which toolbar affordances show (e.g.
strip-audio is hidden for an audio playlist). The parallel `audio*` Manager
state exists only because the audio channel runs independent of what Manager
browses — but that independence is needed in the **player overlay**, which
derives its file list from `activeAudioPlaylist` directly, not from Manager
state. In Manager there is one managed playlist at a time, so one set of
file/selection/filter state suffices.

### Settled

- No per-type scroll/selection/filter tokens. Video and image are mutually
  exclusive; only audio has an independent channel, and that independence lives
  in the player overlay, not in Manager.
- Type becomes UI branching: hide type-inapplicable toolbar buttons rather than
  routing through a scope-keyed state split.
- The audio transport inlet stays pinned in the sidebar regardless of scope —
  the audio playback channel is independent, so its transport is always present
  while any scope is managed.

### Open questions (resolve before implementing #2)

1. **Is audio a full managed scope in Manager, or transport-only?** "In
   management only for audio transport" reads two ways: (a) selecting an audio
   playlist in the audio scope shows its files/tags in the center panel
   generically, like any other type; or (b) audio file/tag management lives
   only in the player overlay, and Manager's audio presence is just the pinned
   transport inlet. This decides whether the audio sidebar scope drives the
   center panel at all, and whether the `audio*` Manager state is deleted or
   merely merged into the generic managed-playlist slot.
2. **Selection vs activation in Manager.** Selecting a playlist in a scope sets
   it as the managed (browse) playlist and updates that scope's last-managed
   memory. Confirm this never starts/stops a playback channel (Manager mode
   isn't playing), and that activation for player mode stays on
   `beginPlayback(of:)`.

## Relationship to the overlay LibrarySurface

- The shared `LibrarySurface` (Task 15) already removes audio's *player-overlay*
  dependence on a separate surface; it derives from `activeAudioPlaylist`.
- If #2 answers Q1 as (b), the audio scope drops out of Manager center entirely
  and the `audio*` Manager state is deleted; the overlay's `LibraryContext`
  becomes the sole consumer of `audioFilteredFiles` and friends.
- If (a), the generic managed-playlist slot subsumes both, and the overlay's
  audio context reads the same generic derivation keyed to `activeAudioPlaylist`.

## Reference points (at time of writing)

- `ManagerScope`: `AppState.swift:32`.
- Scope routing accessors: `AppState.swift:337`–423.
- `managerScope` didSet (drops service filter, recomputes both lists):
  `AppState.swift:103`.
- Per-type active slots + `activate(_:)`: `AppState.swift:117`, `319`.
- `PlaylistSidebar` sections / scope branching: `PlaylistSidebar.swift:54`–67,
  `135`, `171`.
- `ScopeTabButton`: `ManagerSplitScene.swift:405`.
- `selectAudioInManager`: `AppState.swift:646`.
