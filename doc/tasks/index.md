# Implementation Tasks

Ordered by dependency. Each task produces a testable, self-contained increment. Later tasks build on earlier ones but never require forward references.

---

## Task 1 — Project scaffold and data models

Set up the Xcode project structure (directories per architecture §14), SwiftData container, and all model types.

**Deliverables:**
- Directory structure: `App/`, `Models/`, `State/`, `Services/`, `MPV/`, `Engines/`, `Views/`, `Extensions/`, `Resources/`
- `ShuTaPlaApp.swift` — `@main` with `WindowGroup`, `ModelContainer` setup, `.commands` removing `.newItem`
- `AppConstants.swift` — extension maps (video/image/audio extensions), dominance threshold (80%)
- All SwiftData models: `Playlist`, `PlaylistFile`, `AppStateModel`, `GlobalSettings`
- All embedded value types: `PlaylistPreferences`, `FilterState`, `SavedSearch`
- All enums: `MediaType`, `ImageFitMode`, `ViewMode`, `FilterMode`, `TaggingStatus`
- Fetch-or-create singleton pattern for `AppStateModel` and `GlobalSettings`

**Testable:**
- Models can be instantiated and persisted in an in-memory SwiftData container
- Singleton fetch-or-create returns same instance on repeated calls
- Embedded Codable structs round-trip through SwiftData correctly
- Enum raw values encode/decode

---

## Task 2 — TagParser service

Pure-function service with no dependencies on other app code.

**Deliverables:**
- `TagParser.swift` — `parseTags(from:)`, `addTag(_:to:)`, `removeTag(_:from:)`, `renameTag(from:to:in:)`
- Parsing: find `\[[^\]]*\]` groups, handle zero (untagged), one (valid), multiple (invalid)
- Tag validation: letters, digits, underscore, minimum 3 chars
- Case-insensitive matching, on-disk casing preserved
- Removing last tag removes empty brackets from filename

**Testable:**
- Parameterized Swift Testing tests (`@Test(arguments:)`) covering:
  - Valid single-bracket filenames
  - Untagged filenames (no brackets)
  - Invalid tagging (multiple bracket groups)
  - Empty brackets
  - Short tags (< 3 chars) filtered out
  - Special characters rejected
  - Tag add/remove/rename produce correct filenames
  - Bracket removal when last tag removed

---

## Task 3 — BookmarkService and FileSystemService

File system layer: security-scoped bookmarks, folder scanning, file rename/trash.

**Deliverables:**
- `BookmarkService.swift` — create bookmarks from URLs, resolve with scoped access, reference counting for concurrent access, stale bookmark detection
- `FileSystemService.swift` (actor) — `scanFolder(bookmark:)`, `updatePlaylist(_:)`, `trashFiles(_:)`, `renameFile(at:to:)`
- File classification by extension using `AppConstants` maps
- Dominance detection (≥ 80% threshold)
- Fisher-Yates shuffle for initial ordering
- `ScanResult`, `UpdateDelta`, `TagParseResult` value types (Sendable)
- `FileSystemProviding` protocol for mock injection

**Testable:**
- Integration tests with temp directories: create known file structures, scan, verify classification and counts
- Update detection: add/remove files between scans, verify delta
- Rename: verify file renamed on disk and new URL returned
- Trash: verify file moved to trash
- Dominance threshold: 80% video → auto-video, 70% → mixed
- Mock conformance compiles and works in test

---

## Task 4 — AppState and Welcome view

Runtime state object and the first visible UI: the welcome screen.

**Deliverables:**
- `AppState.swift` — `@MainActor @Observable`, holds `ModelContext`, active playlist references, app mode (`.welcome`, `.manager`, `.player`), environment injection
- `WelcomeView.swift` — prominent "Add Playlist" button, triggers folder picker
- Folder picker → FileSystemService scan → playlist creation flow (auto-detect media type or prompt for mixed)
- On launch: fetch `AppStateModel` from SwiftData, determine mode (welcome if no playlists exist)
- Settings scene stub (Cmd+, opens empty `SettingsView`)

**Testable:**
- Launch with empty database → welcome mode
- Pick a folder → playlist created in SwiftData with correct media type
- Mixed folder → user prompted to choose type
- After creating first playlist → mode switches to manager

---

## Task 5 — Manager mode: playlists panel (left sidebar)

The left collapsible panel with playlist CRUD and sections.

**Deliverables:**
- `ManagerView.swift` — `HSplitView` three-column layout (left, center, right panels), collapse/expand for side panels
- `PlaylistSidebar.swift` — sections by media type (Video, Image), playlist rows with selection, Audio hint at bottom
- Playlist CRUD: create (folder picker), rename (inline editing), delete (with confirmation)
- Playlist reorder via drag within section
- `@Query` filtered by `mediaType`, sorted by `sortOrder`
- Selecting a playlist sets it as active in AppState, triggers background update

**Testable:**
- Create playlist → appears in correct section
- Rename → name updated in SwiftData and sidebar
- Delete → removed from SwiftData, sidebar updates
- Reorder → `sortOrder` updated correctly
- Select playlist → AppState reflects active playlist
- Collapse/expand panel toggles width

---

## Task 6 — Manager mode: center panel (file list, header)

The file list and playlist header with basic controls.

**Deliverables:**
- `PlaylistCenterView.swift` — playlist header (name, Play button, Reshuffle/Update buttons, view-mode toggle)
- `FileListView.swift` — `LazyVStack`-based list, file rows with name and tag chips
- `FileRowView.swift` — filename display, tag chips, selection highlight, context menu (rename, show in Finder, delete)
- File interactions: click to select, multi-select (shift/cmd click), double-click to play
- Rename file inline → TagParser + FileSystemService rename on disk → model update
- Delete (single and multi-select) → trash on disk, remove from playlist
- Show in Finder → `NSWorkspace.shared.activateFileViewerSelecting`
- Reshuffle and Update button actions (invoke FileSystemService, update models)
- Skipped-files notice, invalid-tagging notice

**Testable:**
- File list renders all files from active playlist
- Click selects, shift-click extends, cmd-click toggles
- Rename updates filename on disk and in model
- Delete moves to trash, removes from list
- Reshuffle produces new random order
- Update detects new/removed files
- View-mode toggle switches between list and gallery (gallery can be stub for now)

---

## Task 7 — Manager mode: tag panel (right sidebar) and filtering

Tag editing and filter controls.

**Deliverables:**
- `TagSidebar.swift` — right collapsible panel, tag editor for selected file(s)
- `TagEditorView.swift` — multi-select chip input with dropdown suggestions, tag input hotkeys (arrows, delete, enter, esc)
- Tag add/remove on selected files → file rename on disk → model update → tag frequency cache update
- Multi-select tag editing: show intersection of tags, add applies to all, remove applies to all that have it
- Playlist-wide tag operations: rename tag across all files, remove tag across all files
- `FilterBar.swift` — tag multi-select, AND/OR switch, "Untagged" toggle, "Invalid tagging" toggle
- Saved multi-tag searches: save, list, re-select
- Filtered file list: computed and cached on AppState, drives file list display
- Filter state persisted per playlist

**Testable:**
- Tag editor shows correct chips for single file
- Adding tag renames file, updates chips, updates frequency cache
- Multi-select shows tag intersection
- AND filter: only files with ALL selected tags shown
- OR filter: files with ANY selected tag shown
- "Untagged" filter shows files with no brackets
- "Invalid tagging" filter shows files with multiple bracket groups
- Saved search: save, recall, produces same filter state
- Switching playlists restores that playlist's filter

---

## Task 8 — ThumbnailService and gallery view

Thumbnail generation and the gallery view mode.

**Deliverables:**
- `ThumbnailService.swift` — async thumbnail generation for images (CGImageSource) and videos (mpv screenshot or ffmpeg)
- In-memory cache (`NSCache`) and on-disk cache (Caches directory)
- Cache key: relative path + modification date
- `FileGalleryView.swift` — `LazyVGrid` with thumbnails, async loading, cancellable on scroll
- Same file interactions as list view (click, double-click, multi-select, context menu)
- View-mode toggle in playlist header switches between `FileListView` and `FileGalleryView`

**Testable:**
- Image thumbnail generated at correct size
- Cache hit returns immediately without regeneration
- Stale cache (different modification date) regenerates
- Gallery renders thumbnails in grid layout
- File interactions work same as list view

---

## Task 9 — mpv integration (MPVClient, MPVMetalView)

The C-to-Swift bridge for libmpv and the Metal rendering surface.

**Deliverables:**
- `mpv-bridging.h` — C bridging header for libmpv
- `MPVEvent.swift` — Swift enum mapping mpv events (time-pos, duration, pause, eof-reached, etc.)
- `MPVClient.swift` — Swift wrapper around `mpv_handle`:
  - Serial `DispatchQueue` for all mpv API calls
  - `loadFile`, `play`, `pause`, `stop`, `seek(to:)`, `seek(by:)`, volume, isLooping
  - `mpv_observe_property` for time-pos, duration, pause, eof-reached
  - `mpv_set_wakeup_callback` → events into `AsyncStream<MPVEvent>`
  - `@unchecked Sendable` with documented safety invariant
- `MPVMetalView.swift` — `NSView` subclass with `CAMetalLayer`, mpv render context via Vulkan/MoltenVK, resize handling
- Build phase: copy and sign `libmpv.dylib`, `libMoltenVK.dylib`, and dependencies into `Frameworks/`
- mpv configured with `--vo=gpu-next --gpu-api=vulkan --gpu-context=moltenvk`

**Testable:**
- MPVClient creates handle without crash
- Load a test video file → events stream produces time-pos and duration updates
- Play/pause/stop commands change state observable via events
- Seek produces updated time-pos
- Volume get/set round-trips correctly
- MPVMetalView renders frames (visual verification)

---

## Task 10 — VideoPlaybackEngine and ImagePlaybackEngine

Playback engines that own MPVClient (video) or timer (images) and expose observable state.

**Deliverables:**
- `VideoPlaybackEngine.swift` — owns MPVClient, consumes events, exposes `currentTime`, `duration`, `isPlaying`, `isLooping` as observable properties, `loadFile`, `advanceToNext`, `returnToPrevious`, `seek(by:)`, EOF → advance
- `AudioPlaybackEngine.swift` — owns separate MPVClient configured with `--vo=null`, same interface as video engine
- `ImagePlaybackEngine.swift` — loads images via `CGImageSource`, publishes `currentImage`, `fitMode`, `transform`, slideshow timer, `cycleFitMode` (fit → cover → original)
- Pan and zoom: `MagnifyGesture`, `DragGesture`, scroll wheel via NSView bridge, transform reset on file change

**Testable:**
- VideoPlaybackEngine: load file → isPlaying becomes true, currentTime advances
- EOF event → advanceToNext called (verify with mock coordinator)
- Loop toggle → mpv loop-file property set
- AudioPlaybackEngine: load file → plays audio (no video output)
- ImagePlaybackEngine: load image → currentImage published, transform at identity
- Slideshow timer: fires after interval, advances to next
- Fit mode cycle: fit → cover → original → fit

---

## Task 11 — PlaybackCoordinator and basic Player mode

Orchestration of engines and the player view shell.

**Deliverables:**
- `PlaybackCoordinator.swift` — owns all three engines, enforces mutual exclusivity (one video XOR image, plus one audio), `play(playlist:)`, `pauseAll()`, `unpauseAll()`, `stop(playlist:)`
- Track which audio was independently paused for correct unpause semantics
- `PlayerView.swift` — fullscreen container, switches between `VideoPlayerView` and `ImagePlayerView` based on active playlist type
- `VideoPlayerView.swift` — hosts `MPVMetalView` via `NSViewRepresentable`
- `ImagePlayerView.swift` — image display with pan/zoom gestures
- Fullscreen transition: `NSWindow.toggleFullScreen` via NSView bridge on entering/exiting player mode
- `PauseOverlay.swift` — opaque overlay with Unpause and Stop buttons
- Basic `[p]` pause and `[space]` unpause/next

**Testable:**
- PlaybackCoordinator: start video → stop image, start image → stop video
- Start audio → runs in parallel with video/image
- pauseAll → both channels paused, unpauseAll → both resumed
- Audio was independently paused → unpauseAll does not unpause it
- Player view enters fullscreen, shows correct content for video vs. image
- Pause overlay appears on `[p]`, Unpause resumes, Stop returns to manager

---

## Task 12 — HotkeyRouter and player hotkeys

Global key event handling and routing.

**Deliverables:**
- `HotkeyRouter.swift` — `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`, routing priority chain (text field → esc chain → space → audio overlay → player/manager)
- All player hotkeys: space, arrows, `[p]`, `[esc]`, `[delete]`, `[shift]` (fit mode), `[l]` (loop), `[right option]+arrows` (seek ±3s)
- Manager mode hotkeys: `[arrow down/up]` (audio overlay), `[esc]` (close window), `[delete]` (trash selected)
- Right Option key detection via `event.keyCode == 61`
- Text input detection: skip hotkey processing when first responder is text field

**Testable:**
- Synthetic NSEvent with `[space]` when playing → advances to next file
- `[space]` when paused → unpauses
- `[p]` → pauses, shows overlay
- `[esc]` priority: overlay open → closes overlay, playing → pauses, paused → closes window
- `[l]` → loop toggles
- `[right option]+[arrow right]` → seek +3s
- Text field focused → keys pass through to text field, not hotkey router
- Arrow keys with audio overlay visible → routed to audio controls

---

## Task 13 — OverlayManager and hover zones

Overlay visibility, exclusivity rules, and edge-of-screen hover detection.

**Deliverables:**
- `OverlayManager.swift` — `@MainActor @Observable`, `Set<Overlay>` state, `show()`/`hide()` with exclusivity rules from feature spec
- `HoverZone.swift` — `NSTrackingArea` wrapper via `NSViewRepresentable`, thin tracking rects at window edges
- Top hover → compact audio overlay
- Left hover → playlists overlay
- Bottom hover → playback controls bar
- Animated transitions: `.move(edge:)` with `withAnimation` in show/hide
- Suppression rules: Files & Tags suppresses left/bottom hover; Extended audio suppresses all hover

**Testable:**
- Show audioExtended → filesTags and playlistsSidebar removed from active set
- Show filesTags → audioCompact and bottomControls removed
- Show audioCompact → closing on hotkey overlay open
- Hover zone fires callback on cursor enter/exit at screen edge
- Animated transitions play correctly (visual verification)

---

## Task 14 — Player overlays: bottom controls, Files & Tags, Playlists

The three major overlays in Player mode.

**Deliverables:**
- `PlaybackControlsBar.swift` — bottom hover: previous, stop, next, loop toggle, progress/scrub, volume slider (video); previous, stop, next, slideshow toggle, interval selector (image); file list button to toggle Files & Tags
- `FilesTagsOverlayView.swift` — slides up from bottom, two sections: file list with filter controls (reuses FilterBar), tag editor (reuses TagEditorView). File interactions: double-click to jump, rename, delete, show in Finder, multi-select
- `PlaylistsOverlay.swift` — left hover: video and image sections (read-only, no CRUD), audio hint at bottom. Selecting a playlist starts playing immediately
- Volume slider per video/audio playlist, persisted
- Progress bar / scrub for video (seeks via MPVClient)
- Slideshow interval selector for image playlists

**Testable:**
- Bottom controls: previous/next advance files, loop toggles, volume changes, scrub seeks
- Files & Tags: file list shows filtered files, double-click jumps player, tag edits rename files
- Playlists overlay: selecting playlist starts it, audio hint opens extended audio
- Controls dismiss on mouse leave (via hover zone)

---

## Task 15 — Audio overlay (compact and extended)

The audio player UI that coexists with video/image playback.

**Deliverables:**
- `AudioOverlayCompact.swift` — current track info, play/pause, prev/next, stop, progress/scrub, volume, loop toggle
- `AudioOverlayExtended.swift` — expands compact to include: audio playlist selector (audio playlists only), file list with filtering, tag editor for current track
- Audio overlay state machine: Hidden → Compact → Extended via `[arrow down]`, back to Hidden via `[arrow up]`
- Top-edge hover → compact (auto-dismiss on mouse leave)
- `[arrow down]` compact → stays open until explicitly closed
- Audio hotkey context switching: when audio overlay visible, arrows/space target audio playlist
- Audio playlist selection in extended view → starts playing selected audio playlist
- In Manager mode: Audio hint in playlists panel bottom → opens compact/extended overlay

**Testable:**
- Arrow down from hidden → compact appears, arrow down again → extended
- Arrow up from either → hidden
- Top hover → compact, mouse leave → dismisses
- Audio controls: play/pause/prev/next/stop work on audio engine
- Extended: selecting audio playlist switches audio playback
- Tag editing in extended overlay renames audio files

---

## Task 16 — Settings, persistence, and lifecycle

Global settings UI, full state persistence, and app lifecycle handling.

**Deliverables:**
- `SettingsView.swift` — global defaults: slideshow interval, file-position persistence, image fit mode
- Per-playlist preference overrides surfaced in playlist header or context
- File-position persistence: write position every 5s during playback and on file change/stop (when enabled)
- App lifecycle:
  - Launch: restore AppState, reconstruct PlaybackCoordinator, restore paused playlists in paused state, restore window frame
  - Window close (not quit): persist state, pause playlists, hide window, keep app running
  - Window reopen (Dock click): restore exact prior state
  - App termination: final persist of all positions and state
- Window frame persistence (debounced on move/resize)
- Stale bookmark handling: inline error on playlist, option to re-select folder

**Testable:**
- Change global default → new playlists use it
- Per-playlist override → overrides global
- File-position persistence: stop and restart → resumes at saved position
- Quit and relaunch → active playlists, paused state, window frame restored
- Close window → app still running, reopen restores state
- Stale bookmark → error shown, re-select folder works

---

## Task 17 — Fullscreen polish, window management, and HDR

Edge cases around fullscreen, single-window enforcement, and HDR support.

**Deliverables:**
- `NSWindow+Fullscreen.swift` — fullscreen helpers, animated transitions
- Window close vs. quit behavior: closing hides window, Dock click reopens
- Fullscreen entry/exit synced with player mode transitions
- HDR video: mpv `--target-colorspace-hint=yes`, `CAMetalLayer.wantsExtendedDynamicRangeContent = true`
- HDR images: `CGImageSource` with `kCGImageSourceShouldAllowFloat`, EDR-capable layer
- Single-window enforcement (`.commands { CommandGroup(replacing: .newItem) {} }`)

**Testable:**
- Enter player → fullscreen, exit → windowed, no flicker or stale state
- HDR video renders with extended dynamic range on capable display
- HDR image displays with EDR
- Cmd+N does nothing (new window removed)
- Close window → app alive, Dock click → window reappears in prior state

---

## Task 18 — Accessibility

VoiceOver and macOS accessibility support.

**Deliverables:**
- All buttons use `Button` (not `onTapGesture`)
- File list rows: `accessibilityLabel` with filename and tag summary
- Tag chips: `accessibilityElement(children: .combine)`
- Collapsible panels: `accessibilityValue` ("collapsed"/"expanded")
- Filter controls: explicit `accessibilityLabel`
- Pause overlay buttons: standard `Button`
- Playback controls: `accessibilityLabel` for icon-only buttons
- Volume sliders: `accessibilityValue` with percentage
- `@ScaledMetric` for custom spacing
- Semantic fonts (`.body`, `.headline`) and colors (`.primary`, `.secondary`)

**Testable:**
- VoiceOver navigation through all interactive elements
- Labels read correctly for buttons, sliders, file rows
- Dynamic Type scaling doesn't break layout
- Light/dark mode renders correctly with semantic colors

---

## Dependency graph

```
Task 1 ─── Data Models
  │
  ├── Task 2 ─── TagParser
  │     │
  │     └── Task 3 ─── FileSystem + Bookmarks
  │           │
  │           └── Task 4 ─── AppState + Welcome
  │                 │
  │                 ├── Task 5 ─── Playlists Panel
  │                 │     │
  │                 │     └── Task 6 ─── File List + Header
  │                 │           │
  │                 │           ├── Task 7 ─── Tags + Filtering
  │                 │           │
  │                 │           └── Task 8 ─── Thumbnails + Gallery
  │                 │
  │                 └── Task 9 ─── mpv Integration
  │                       │
  │                       └── Task 10 ── Playback Engines
  │                             │
  │                             └── Task 11 ── Coordinator + Player Shell
  │                                   │
  │                                   ├── Task 12 ── Hotkeys
  │                                   │
  │                                   ├── Task 13 ── Overlays + Hover
  │                                   │     │
  │                                   │     └── Task 14 ── Player Overlays
  │                                   │           │
  │                                   │           └── Task 15 ── Audio Overlay
  │                                   │
  │                                   └── Task 16 ── Settings + Lifecycle
  │
  └── Task 17 ── Fullscreen + HDR (after Tasks 11, 16)
  │
  └── Task 18 ── Accessibility (after all UI tasks)
```

Tasks 5–8 (Manager UI) and Tasks 9–10 (mpv/engines) can be developed in parallel once Task 4 is complete.
