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
- **Audio is a full managed scope, not transport-only (was Q1, resolved (a)).**
  Selecting an audio playlist in the audio scope manages it generically like any
  other type — its files in the center panel, its filter and tags in the
  inspector panel — with every Manager feature the visual types have. The
  independent audio *transport* channel is a separate concern: it is truly
  independent only while a non-audio playlist is the one being managed or played.
  So the `audio*` Manager state is not deleted; it merges into the single generic
  managed-playlist slot.
- **Selecting manages; it does not start playback (was Q2).** Selecting a
  playlist in a scope sets it as the managed (browse) playlist and updates that
  scope's last-managed memory. Manager is a stopped/browse context, so selection
  never *starts* a playback channel — actual play stays on `beginPlayback(of:)`.
  Channel teardown on switch still applies: switching the audio playlist stops
  the previous audio transport (the audio channel follows its selected playlist),
  and switching the managed visual playlist nils the other visual channel via
  `activate(_:)` (in Manager a no-op in practice, since the visual channel is
  already stopped while browsing). The audio transport is independent of the
  visual channels: switching image or video never stops it.
- **Player overlays are channel-pinned; only the Manager bar follows the scope.**
  Filter routing splits three ways. The Manager's one shared `FilterBar` follows
  `managerScope` (`FilterScope.manager`), since a single control there serves
  whichever scope is selected. Each player overlay is bound to one channel and
  routes directly — the visual overlay to the visual API (`.visual`), the audio
  overlay to the audio API (`.audio`). An overlay must never key off
  `managerScope`: the audio overlay coexists with the visual player, and the
  visual overlay outlives whatever scope was last managed. (Today the visual
  overlay still rides `.manager`; that is behavior-equivalent only because
  `managerScope` is `.visual` whenever it is open. Adding the explicit `.visual`
  scope removes that hidden assumption.)

## Relationship to the overlay LibrarySurface

- The shared `LibrarySurface` (Task 15) already removes audio's *player-overlay*
  dependence on a separate surface; it derives from `activeAudioPlaylist`.
- With Q1 resolved as (a), the generic managed-playlist slot subsumes both the
  visual and audio Manager state, and the overlay's audio context reads the same
  generic derivation keyed to `activeAudioPlaylist`.
- The overlay filter routing (`FilterScope.visual` / `.audio`) is the player-side
  half of the same split: Manager browses through the scope, the overlays drive
  their pinned channels directly.

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
