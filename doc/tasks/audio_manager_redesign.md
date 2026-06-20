# Audio Manager Redesign

## Goal

Make Manager mode a two-scope library — **visual** (video + image) and **audio** —
instead of a visual-only library with audio hidden behind a top-edge overlay. Audio
becomes first-class Manager content, reusing the same sidebar / center / filter / tag
machinery as visual (minus gallery view). The top-edge audio overlay becomes
**player-mode only**, which removes the titlebar collision it had in Manager mode. A
compact audio transport inlet sits at the top of the left panel so the independent
audio channel stays controllable while browsing either scope.

The audio channel and the visual channel are independent: switching Manager scope is a
view switch only — it never starts, stops, or loads any channel, and the two scopes'
state never overwrite each other.

## Premise (current state)

The toolbar header carries little: the sidebar/inspector collapse buttons and the
tag-manager toggle. Manager mode shows only visual playlists; audio lives entirely in a
hover overlay anchored to the window's content-area top, which in Manager mode lands
below the titlebar.

## Manager scopes

New state `AppState.managerScope: ManagerScope { case visual, audio }`.

| | Sidebar shows | Center shows | Toolbar acts on |
|---|---|---|---|
| Visual | Video + Image sections | `selectedPlaylist` / `filteredFiles` | `selectedPlaylist` |
| Audio | Audio section | `activeAudioPlaylist` / `audioFilteredFiles` | `activeAudioPlaylist` |

**In Manager mode, selecting a different audio playlist stops the currently playing
one** and makes the newly selected playlist the active, **stopped** playlist (the inlet
then shows the Stopped transport). Only one audio playlist is ever live, so switching
never leaves a background playlist playing — this keeps the edge cases simple.

In the **player-mode extended overlay**, selecting a different audio playlist **starts
playing it** immediately, matching how selecting a playlist in the visual player overlay
behaves.

## Toolbar

Replaces the title + sidebar-toggle strip.

- **Left cluster — scope tabs:** `[Visual] [Audio]`, active one highlighted. Clicking
  the *active* scope collapses the left panel; clicking *either* while collapsed
  expands it and sets that scope. (Drives `ManagerView`'s existing `columnVisibility`;
  the automatic sidebar-toggle button is removed.). Aligned left.
- **Left cluster — New Playlist (`+`):** opens the add-folder flow; once the playlist's
  type is known it switches scope to match and selects the new playlist. Replaces the
  sidebar's bottom `+` button. Aligned right.
- **Center — title:** current playlist name as the window title (`.navigationTitle`),
  placeholder `"ShuTaPla"` when nothing is selected. Aligned left.
    - Visual: Play · Reshuffle · List/Gallery toggle · Settings *(placeholder, no-op)*. Aligned right.
    - Audio: Reshuffle · Settings *(placeholder)*. Aligned right.
- **Right cluster — tag controls:**
  - The existing tag-panel controls (Manage Tags, Toggle Tags inspector) and collapse button, applied
    to the active scope's playlist.

Visual **Play** enters Player mode (fullscreen). Audio has no toolbar Play — audio
playback starts from the inlet and stays in Manager.

## Left panel

- **Top: audio transport inlet** (replaces the current `audioHint` row). Always present,
  in **both** scopes — the audio channel is parallel to whatever you're browsing.
  Pinned (non-scrolling) above the playlist list. It collapses with the panel; a
  floating/status-bar fallback when collapsed is deferred (see below).
- **Below: the playlist list** for the active scope, with the existing
  create / inline-rename / delete / drag-reorder. The bottom `+` add button is removed
  (replaced by the toolbar's New Playlist).

### Audio inlet contents

- **No audio playlist is active:** music icon + **Play**, which cascades:
  - no audio playlists exist → opens the add-audio-playlist flow;
  - audio playlists exist → starts the first one.
- **An audio playlist is active:** the state-dependent transport (below). Volume is a
  button that reveals a slider in a popover. Play here continues the active playlist, the
  same way the visual toolbar's Play resumes a visual playlist.
  - The **track name** (small text) and the thin **track-progress bar** appear only when
    a current audio file is available (`currentAudioFile != nil`). An active playlist
    with no current file yet shows just the transport.

### Audio transport — state-dependent button set

Render only controls that are actionable in the current state — no dead buttons. This
logic is **shared** by the inlet and the player-mode overlay.

| State | Controls |
|---|---|
| Stopped | Play · Volume |
| Playing | Previous · Pause · Stop · Next · Loop · Volume |
| Paused  | Previous · Play · Stop · Next · Loop · Volume |

Previous / Next / Loop / Stop appear only once the channel is live.

## Center panel (files)

Reuse the visual Manager center for both scopes, parameterized by scope:

- File **list** only — audio has no gallery view.
- **Notice bar** (untagged / invalid tagging / skipped) — shared.
- **Filter bar** — shared, bound to the scope's filter state.
- **Multi-select** batch tagging / delete — audio gains full parity with visual.

Reads and writes route to the scope's slots and stay parallel, never cross-writing:

| | Visual | Audio |
|---|---|---|
| Playlist | `selectedPlaylist` | `activeAudioPlaylist` |
| Files | `filteredFiles` | `audioFilteredFiles` |
| Selection | `selectedFileIDs` | *(new audio selection set)* |
| Filter mode | `filterMode` | `audioFilterMode` |

Audio files also get duration fetching (extend `DurationService` to audio).

## Tag inspector

The trailing `.inspector` `TagSidebar` is shared; it edits the active scope's selected
files, fileters and searches.

## Player-mode audio overlay (unified compact / extended)

- Remove the redundant heading from the extended overlay.
- Make compact and extended **one** layout with a compact/expanded state: compact shows
  only the transport; expanding reveals the lower section (playlists + files & tags),
  reusing partials from `PlaylistsOverlay` and `FilesTagsOverlayView` rather than the
  bespoke columns. Conceptually: the compact overlay is the audio playback-controls
  overlay; the extended overlay is the three player overlays (controls + playlists +
  files & tags) combined into one view.
- Keep the add-playlist `+` button in the extended view.
- The overlay mounts **only** in Player mode (`RootView` stops mounting
  `audioOverlayLayer` in Manager mode).

## Reuse map

- `PlaylistSidebar` → scope-aware sections + pinned audio inlet; drop `audioHint` and
  the bottom `+`.
- `PlaylistCenterView` / `FileListView` / `FilterBar` / notice bar / `TagSidebar` →
  scope-parameterized, serve both scopes.
- New shared transport view (state-driven button set) used by the inlet and the
  overlay.
- Extended overlay → composed from `PlaylistsOverlay` + `FilesTagsOverlayView` partials
  + the shared transport.
- `RootView` → `audioOverlayLayer` only in Player mode.

## Deferred / out of scope (v1)

- Floating audio controls when the left panel is collapsed.
- Audio control via keyboard in Manager mode (mouse-driven for now).
- Per-playlist Settings (placeholder button only).

## Assumptions

- **`managerScope` persistence:** not persisted — Manager always opens in visual scope.

## Implementation plan

Phased so each step builds, keeps tests green, and is shippable on its own. No SwiftData
schema changes — `managerScope` and the audio selection set are transient `@MainActor`
state, so there's no migration.

### Phase 1 — Scope state + scoped data routing (no visible change) ✅

- Add `enum ManagerScope { case visual, audio }` and `AppState.managerScope` (default
  `.visual`).
- Add `audioSelectedFileIDs: Set<UUID>` parallel to `selectedFileIDs`.
- Add scope-routed accessors that read/write the right slot by `managerScope`:
  `managerPlaylist`, `managerFiles`, `managerSelection` (get/set), `managerFilterMode`.
  Visual routes to `selectedPlaylist` / `filteredFiles` / `selectedFileIDs` /
  `filterMode`; audio to `activeAudioPlaylist` / `audioFilteredFiles` /
  `audioSelectedFileIDs` / `audioFilterMode`.
- **Tests** (`AppStateTests`): each accessor returns the correct slot per scope, and
  flipping `managerScope` never mutates the other scope's slots. Image-backed fixtures —
  pure bookkeeping, no engine.

### Phase 2 — Sidebar scopes + audio inlet + selection rule ✅

- `PlaylistSidebar`: show Video + Image (visual) or Audio (audio) by scope; drop
  `audioHint`. *(The bottom `+` stays through Phase 2 — it is the only add-playlist
  affordance in Manager until the toolbar's New Playlist replaces it in Phase 3, so
  removing it now would strand playlist creation.)*
- Extract a shared `AudioTransport` view driving the state-dependent button set
  (Stopped / Playing / Paused). Mount it as the pinned inlet at the sidebar top, in both
  scopes.
- Implement the Manager **stop-on-switch**: selecting a different audio playlist stops
  the live channel and leaves the new one active + stopped. Wire the inlet **Play
  cascade** (none → add, exist → first, active → continue).
- **Tests** (`PlaybackCoordinatorTests` / `AppStateTests`): stop-on-switch leaves the
  old playlist stopped and the new one active + stopped; the Play cascade picks the
  right branch. Audio channel via the window-free `AudioPlaybackEngine`, empty `Data()`
  fixtures, `defer { coordinator.shutdown() }`.

### Phase 3 — Toolbar consolidation ✅

- Move the `PlaylistCenterView` header controls into `ManagerView.toolbar`; delete the
  header.
- Leading region: scope tabs (left) + New Playlist `+` (right); the tabs drive
  `columnVisibility` collapse/expand. Title via
  `.navigationTitle(managerPlaylist?.name ?? "ShuTaPla")`.
- Detail region (right): visual → Play · Reshuffle · List/Gallery · Settings
  (placeholder); audio → Reshuffle · Settings (placeholder). Trailing region keeps the
  existing tag controls + inspector toggle.
- New Playlist switches `managerScope` to the created type and selects it. Drop the
  sidebar's bottom `+` (the toolbar's New Playlist now carries it; kept through Phase 2).
- **Tests**: create-playlist-switches-scope routing in `AppState`; the SwiftUI toolbar
  itself is covered by build + smoke, since its logic lives in tested `AppState` actions.

*Transitional notes (cleared by later phases):*
- *The audio-scope center is a placeholder (`ContentUnavailableView`, "files managed from
  the player overlay") — accurate while the overlay still mounts in Manager. Phase 4
  replaces it with the real scoped center; Phase 5 removes the overlay from Manager.*

#### Toolbar shell — Option B2 (AppKit), status and findings

The Manager shell is an `NSSplitViewController` (`ManagerSplitScene.swift`) hosting the three
SwiftUI panes, with a custom `NSToolbar` whose three regions (sidebar / center / inspector) are
bounded by `NSTrackingSeparatorToolbarItem`s pinned to the split dividers. `ManagerChrome`
(`@Observable`) is the shared source of truth for sidebar collapse, inspector visibility, and
tag-management mode. The controller is hosted *inside* the SwiftUI `WindowGroup` via
`NSViewControllerRepresentable` (`ManagerView` → `ManagerSplitScene`).

**Working:**
- *Pane resize.* The representable's `sizeThatFits` returns the full proposed size. Without it,
  SwiftUI's default pass sizes the controller to its fitting width (sum of pane minimums) and
  centers it, leaving margins — so a divider drag couldn't hand freed width to the center pane and
  a collapsing pane detached from the window edge. Returning the proposed size pins the split edge
  to edge; with center at the lowest `holdingPriority`, a center↔inspector drag resizes those two
  panes and inspector drag-collapse stays pinned.
- *Scope tabs.* Custom toggle buttons (`ScopeTabButton`) with a subtle gray capsule highlight on
  the active scope (no accent fill), gray-on-hover for the inactive one — matching the system
  toolbar's selected-toggle look. They also drive collapse: click the active scope to collapse the
  sidebar, click either while collapsed to expand + select. A native segmented `Picker` gives the
  exact look for free but **can't** report a click on the already-selected segment, so it can't
  drive the reclick-collapse — hence the custom button.

**Known limitation — New Playlist `+` overflow on collapse (accepted for now):**
`+` is pinned to the sidebar's trailing (divider) edge (a `flexibleSpace` before it, ahead of the
sidebar tracking separator), so it moves with a sidebar resize. The desired Xcode behavior also
**relocates** it next to the leading scope-tab cluster when the sidebar collapses, never falling into
the overflow menu — that part does not work in the current architecture, and item reordering can't
fix it: even leading-grouped right next to the (surviving) scope tabs, `+` overflows. The overflow on
collapse is accepted for now.

Root cause: AppKit's full-height-sidebar toolbar coordination — reserving a sidebar *region* of
toolbar width, pinning its items to the divider, and relocating them on collapse — engages only when
the `NSSplitViewController` is the **window's `contentViewController`**. Here the window's content
controller is SwiftUI's hosting controller (the split is hosted inside the `WindowGroup`), so AppKit
reserves no region and simply overflows whatever leading items don't fit. The `NSTrackingSeparator`
still draws the divider line, but the region/relocate behavior never turns on.

Proper fix (deferred) — the literal intent of B2, "host the whole shell in AppKit": let **AppKit own
the window content**. A container controller swaps between the Manager split controller (native
toolbar coordination) and SwiftUI-hosted Welcome/Player. This requires moving the two global concerns
that currently live in `RootView`'s view lifecycle — the add-playlist flow (`.addPlaylistFlow()`) and
the `HotkeyRouter` `NSEvent` monitor — out to app/`AppState` level so they survive when SwiftUI no
longer owns the content.

Pragmatic fallback (if the refactor isn't taken): put `+` in the sidebar's own bottom bar
(`.safeAreaInset(edge: .bottom)` on `PlaylistSidebar`) — which is where Xcode's actual *add* buttons
live (navigator bottom bar, not the toolbar), so it never overflows and collapses with the panel.

Reference: full-height-sidebar + toolbar coordination needs the split controller as the window's
`contentViewController` with `.fullSizeContentView` and `sidebarTrackingSeparator` — see Apple's
[`sidebarTrackingSeparator`](https://developer.apple.com/documentation/appkit/nstoolbaritem/identifier/sidebartrackingseparator)
docs and the [WWDC20 "new look of macOS" notes](https://mackuba.eu/notes/wwdc20/adopt-new-look-of-macos/).

### Phase 4 — Center-panel parity (filter, tags, multi-select, durations)

- Point `PlaylistCenterView` / `FileListView` / `FilterBar` / notice bar / `TagSidebar`
  at the scoped accessors so they serve both scopes (list only — no gallery for audio).
- Audio gains multi-select batch tagging / delete via `audioSelectedFileIDs`.
- Extend `DurationService` to fetch audio durations.
- **Tests**: filter / select / tag / delete on the audio scope mutate only audio slots;
  duration fetch populates audio files (real audio samples via the stateless extraction
  helpers).

### Phase 5 — Unified player overlay + drop Manager mount

- `RootView`: mount `audioOverlayLayer` only in `.player`.
- Merge compact / extended into one layout — compact transport always, an expandable
  lower section reusing `PlaylistsOverlay` + `FilesTagsOverlayView` partials + the shared
  `AudioTransport`; remove the redundant heading. Keep the extended `+`.
- Overlay selection keeps playing-on-select (matches the visual player overlay).
- **Tests** (`HotkeyRouterTests` / overlay state): reveal / expand transitions; overlay
  selection plays immediately; Manager mode no longer mounts the overlay.
