# Implementation Tasks

Ordered by dependency. Each task produces a testable, self-contained increment. Later tasks build on earlier ones but never require forward references.

Status legend: ✅ = complete (built and tested). Unmarked tasks are not started.

---

## Task 1 — Project scaffold and data models  ✅

**Status: complete.** All models, embedded value types, enums, and singleton fetch-or-create implemented; 9 tests passing. Project is on Swift 6 language mode.

Set up the Xcode project structure (directories per architecture §14), SwiftData container, and all model types.

**Deliverables:**
- Directory structure: `App/`, `Models/`, `State/`, `Services/`, `MPV/`, `Engines/`, `Views/`, `Extensions/`, `Resources/`
- `ShuTaPlaApp.swift` — `@main` with `WindowGroup`, `ModelContainer` setup, `.commands` removing `.newItem`
- `AppConstants.swift` — extension maps (video/image/audio extensions), dominance threshold (80%)
- All SwiftData models: `Playlist`, `PlaylistFile`, `AppStateModel`, `GlobalSettings`
- All embedded value types: `PlaylistPreferences`, `FilterState`, `SavedSearch`
- All enums: `MediaType`, `ImageFitMode`, `ViewMode`, `FilterMode`, `TaggingStatus`, `PlaybackState`, plus runtime-only `CloudStatus` and `ServiceFilter`
- `Playlist.playbackState` persists the per-playlist Stopped/Playing/Paused state; `Playlist.currentFileID` tracks the current file by ID (stays valid through Update prune/append)
- `AppStateModel` holds active playlist IDs (video and image share the visual channel — at most one of the two is non-nil) and the window frame
- Fetch-or-create singleton pattern for `AppStateModel` and `GlobalSettings`

**Testable:**
- Models can be instantiated and persisted in an in-memory SwiftData container
- Singleton fetch-or-create returns same instance on repeated calls
- Embedded Codable structs round-trip through SwiftData correctly
- Enum raw values encode/decode

---

## Task 2 — TagParser service  ✅

**Status: complete.** `parseTags`/`addTag`/`removeTag`/`renameTag` with depth-based bracket scanning and case-insensitive dedup; 43 parameterized/unit tests passing.

Pure-function service with no dependencies on other app code.

**Deliverables:**
- `TagParser.swift` — `parseTags(from:)`, `addTag(_:to:)`, `removeTag(_:from:)`, `renameTag(from:to:in:)`
- Parsing: track bracket nesting — zero pairs (untagged), exactly one balanced pair (valid), more than one pair or any nesting (invalid). A single unmatched `[`/`]` that never forms a pair is ignored, not invalid
- A single empty bracket pair (`[]`) → untagged (cleaned up on next edit); a pair where any token isn't a valid tag (e.g. `[beach ab]`, `[a b c]`) → invalid (surfaced, never silently dropped)
- Tag validation: letters, digits, underscore, minimum 3 chars
- Case-insensitive matching, on-disk casing preserved
- Duplicates never accumulate: `addTag` is a no-op when the file already has the tag (case-insensitively); `renameTag` collapses a resulting within-file duplicate to a single instance
- Removing last tag removes empty brackets from filename

**Testable:**
- Parameterized Swift Testing tests (`@Test(arguments:)`) covering:
  - Valid single-bracket filenames
  - Untagged filenames (no brackets)
  - Invalid tagging (multiple bracket groups, or nested brackets)
  - Stray unmatched bracket ignored (still valid/untagged)
  - Empty brackets (`[]`) → untagged
  - Bracket group with any non-conforming token (too short or disallowed char, e.g. `[beach ab]`, `[a b c]`) → invalid
  - A valid group requires every token to conform (letters/digits/underscore, ≥ 3 chars)
  - Adding a too-short or special-character tag is rejected by the editor
  - Tag add/remove/rename produce correct filenames
  - Adding an already-present tag (any casing) leaves the filename unchanged; rename collapses duplicates
  - Bracket removal when last tag removed

---

## Task 3 — BookmarkService and FileSystemService  ✅

**Status: complete.** `BookmarkService` (create/resolve with scoped-access fallback, reference-counted sessions, stale detection) and the `FileSystemService` actor (`scanFolder`/`updatePlaylist`/`renameFile`/`trashFiles`), with `ScanResult`/`ScannedFile`/`UpdateDelta`/`TrashResult` Sendable value types, the `FileSystemProviding` protocol, and Fisher-Yates shuffle; 15 tests passing.

File system layer: security-scoped bookmarks, folder scanning, file rename/trash.

**Deliverables:**
- `BookmarkService.swift` — create bookmarks from URLs, resolve with scoped access, reference counting for concurrent access, stale bookmark detection
- `FileSystemService.swift` (actor) — `scanFolder(bookmark:)`, `updatePlaylist(_:)`, `trashFiles(_:)`, `renameFile(at:to:)`
- File classification by extension using `AppConstants` maps
- Dominance detection (≥ 80% threshold)
- Fisher-Yates shuffle for initial ordering
- Update always prunes files missing from disk (manual and auto-update); re-reads run in a background Task
- `ScanResult` carries each file's initial cloud status (local / in cloud / downloading)
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

## Task 4 — AppState and Welcome view  ✅

**Status: complete.** `AppState` (`@MainActor @Observable`: `ModelContext`, app mode, active-playlist references with visual-channel exclusivity, fetch-or-create singletons, launch-mode determination) and the folder-picker → scan → creation flow (`addPlaylist`/`confirmPlaylist`/`makePlaylist`, auto-detect dominant type or prompt for Mixed, non-matching files marked skipped, shuffled initial order). `WelcomeView` ("Add Playlist" → `.fileImporter`, Mixed-type confirmation dialog), `RootView` mode switch (Manager/Player placeholders), `SettingsView` stub wired to the `Settings` scene (Cmd+,); 7 tests passing.

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

## Task 5 — Manager mode: playlists panel (left sidebar)  ✅

**Status: complete.** `ManagerView` (three-column `HSplitView` with independently collapsible left/right panels via toolbar toggles; center and tag panels are Task 6/7 placeholders) and `PlaylistSidebar` (a single `@Query` sorted by `sortOrder`, filtered in memory into Video and Image sections, with a collapsed Audio hint at the top for the Task 15 extended overlay). Playlist CRUD on `AppState`: create via folder picker (reuses the add flow), inline rename, delete with confirmation (clears active/selected refs, compacts the section's `sortOrder`), drag reorder (`Array.move` extension), and `select` (sets selected + active, cancels any stale background re-scan and starts a new tracked one). `update(_:)` applies the scan delta — prunes missing files (detaching the inverse so `playlist.files` updates synchronously), appends new ones, rebuilds the tag-frequency cache. 12 `AppStateTests` passing.

The left collapsible panel with playlist CRUD and sections.

**Deliverables:**
- `ManagerView.swift` — `HSplitView` three-column layout (left, center, right panels), collapse/expand for side panels
- `PlaylistSidebar.swift` — sections by media type (Video, Image), playlist rows with selection, collapsed Audio section at the top (opens the extended audio overlay)
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

## Task 6 — Manager mode: center panel (file list, header)  ✅

**Status: complete.** `PlaylistCenterView` (header: name, Play, Reshuffle, Update, list/gallery segmented toggle bound to `preferences.viewMode`; owns the delete confirmation and error alert), `FileListView` (`LazyVStack` of the playlist's playable files, click/shift-click/cmd-click selection via `NSEvent.modifierFlags`, double-click to play, inline rename, per-row context menu, gallery placeholder for Task 8), `FileRowView` (filename + read-only tag chips, selection highlight, inline rename field). `AppState` file ops: `renameFile` (disk rename via `BookmarkService` scoped access + `FileSystemService`, then re-parses tags/path), `deleteFiles` (best-effort trash, prunes trashed from the playlist), `reshuffle` (Fisher-Yates over playable, skipped kept last), `revealInFinder`, shared `selectedFileIDs`, and a temporary `beginPlayback`→Player-mode hook (real playback is Task 11; the Player placeholder has a Back button). Counter notices for untagged/invalid/skipped render when non-zero (clicking to activate a service filter is Task 7). 15 `AppStateTests` passing.

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
- Counter notices for untagged / invalid tagging / skipped files (shown only when the count is non-zero; clicking activates the corresponding service filter — Task 7)

**Testable:**
- File list renders all files from active playlist
- Click selects, shift-click extends, cmd-click toggles
- Rename updates filename on disk and in model
- Delete moves to trash, removes from list
- Reshuffle produces new random order
- Update detects new/removed files
- View-mode toggle switches between list and gallery (gallery can be stub for now)

---

## Task 7 — Manager mode: tag panel (right sidebar) and filtering  ✅

**Status: complete.** `TagSidebar` (right panel: `FilterBar` over the selected playlist's tags + `TagEditorView` for the file-list selection), `FilterBar` (AND/OR tag cloud, saved-search recents, service-filter banner, per-tag playlist-wide rename/remove via context menu), `TagEditorView` (common-tag chips, autocomplete input with enter/arrow/esc handling, invalid-tagging files get a plain rename field and are excluded from batch ops), and `FlowLayout` (wrapping chip layout). `AppState` gains the filtering and tag-editing API: `toggleFilterTag`/`setFilterMode`/`clearTagFilter`, `toggleServiceFilter` (mutually exclusive, overrides the tag filter), `addTag`/`removeTag` (batch, invalid files excluded), `renameTagAcrossPlaylist`/`removeTagAcrossPlaylist`, saved searches (`saveCurrentSearch`/`applySavedSearch`/`removeSavedSearch`, 10 recent unique, move-to-top), and a cached `filteredFiles` (recomputed on selection/filter/edit changes) that drives `FileListView`. Center-panel counter notices now toggle service filters. Filter persisted per playlist; service filter is runtime-only. 22 `AppStateTests` passing.

Tag editing and filter controls.

**Deliverables:**
- `TagSidebar.swift` — right collapsible panel, tag editor for selected file(s)
- `TagEditorView.swift` — multi-select chip input with dropdown suggestions, tag input hotkeys (arrows, delete, enter, esc)
- Invalid-tagging file: editor disables chip editing and shows an "invalid tag syntax" message with a plain filename-rename field; re-enables once the name parses cleanly. Multi-selection excludes invalid files from batch tag ops
- Tag add/remove on selected files → file rename on disk → model update → tag frequency cache update
- Multi-select tag editing: show intersection of tags, add applies to all, remove applies to all that have it
- Playlist-wide tag operations: rename tag across all files, remove tag across all files
- `FilterBar.swift` — tag multi-select, AND/OR switch
- Service filters (Untagged / Invalid tagging / Skipped): activated/deactivated by clicking the counter notices, mutually exclusive with each other, temporarily override the tag filter while active; Manager mode only, runtime-only state
- Saved multi-tag searches: 10 most recent unique combinations (tag set + AND/OR operator), re-applying an existing one moves it to the top, manual removal
- Filtered file list: computed and cached on AppState, drives file list display
- Filter state persisted per playlist; service filters are not persisted

**Testable:**
- Tag editor shows correct chips for single file
- Invalid-tagging file selected → editor shows the "invalid tag syntax" message + rename field, not chips; re-enables after a clean rename
- Adding tag renames file, updates chips, updates frequency cache
- Multi-select shows tag intersection
- AND filter: only files with ALL selected tags shown
- OR filter: files with ANY selected tag shown
- Untagged service filter shows files with no brackets; Invalid tagging shows files with invalid tagging; Skipped lists non-playable files
- Activating a service filter deactivates the other service filters and the tag filter; deactivating restores the tag filter
- Saved search: save, recall, produces same filter state; re-applying an existing combination moves it to the top instead of duplicating
- Switching playlists restores that playlist's filter

---

## Task 8 — ThumbnailService and gallery view  ✅

**Status: complete.** `ThumbnailService` (`@MainActor @Observable`, injected via the environment): images thumbnailed with `CGImageSource`, videos with `AVAssetImageGenerator`; in-memory `NSCache` of decoded `NSImage`s over an on-disk PNG cache in the Caches directory; cache key = SHA-256 of relative path + modification date + size, so an edited file invalidates its stale thumbnail. Generation runs off the main actor — the entry point reads the model, then `nonisolated` workers resolve the bookmark and return PNG `Data`. `FileGalleryView` (`LazyVGrid` of `GalleryCell`s; each loads its thumbnail via `.task(id:)` so the load cancels when scrolled off-screen, shows a film/photo placeholder until ready), with the list view's interactions. The click-selection algorithm and delete-target logic moved to a shared `FileSelection` helper used by both views; `PlaylistCenterView` swaps `FileListView`/`FileGalleryView` on the header's view-mode toggle. 4 `ThumbnailServiceTests` (image thumbnail size, cache-key stability, stale-date invalidation, disk-cache hit without regeneration) + the existing 22 `AppStateTests` pass.

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

## Task 8.1 — Manager UX refinements  ✅

**Status: complete.** A polish pass over the Manager layout and the thumbnail pipeline, plus the sandbox file-access fix that on-disk edits require. Build clean; 26 tests pass.

**Layout.** The three-pane Manager shell uses `NavigationSplitView` (Playlists sidebar + center detail) with the Tag panel as a trailing `.inspector`. Both side regions fill the full window height, are independently resizable, and remember their widths; collapsing one no longer collapses the layout. The sidebar collapses via the system toggle and the inspector via a toolbar button. The Add-Playlist control is a borderless **+** in a `.safeAreaInset` bar at the bottom of the sidebar, so it stays grouped with the playlists.

**File access (sandbox).** The app is sandboxed with `ENABLE_USER_SELECTED_FILES = readwrite` (rename, tag-edit, and trash are disk writes — read-only access blocked them). `AppState.beginFolderAccess(to:)` centralizes scoped access for every file mutation: it starts a scoped session and, when the bookmark is stale or denied, prompts the user with an `NSOpenPanel` to relocate the folder, refreshes and persists the bookmark, then retries.

**Thumbnails.** Generation and PNG decode run off the main actor. Under Approachable Concurrency a `nonisolated async` function runs on the caller's actor, so the CPU-bound workers (`cacheKey`, `produceImage`) are marked `@concurrent` to land on the concurrent pool while staying in the cell's `.task` cancellation chain. The image is decoded into a ready-to-draw `NSImage` off-main, so scrolling never blocks on a draw-time decode. A synchronous in-memory hit (`cachedThumbnail`) serves already-seen cells without disk I/O or a placeholder flash, and gallery tiles are uniform 4:3 (image center-cropped to fill). The on-disk cache key is the SHA-256 of relative path + modification date + max pixel size.

**Optimistic progress indicators.** `AppState` exposes three transient states the sidebar renders as spinners: a folder being scanned into a playlist appears immediately as a row with a spinner; a playlist with a background re-scan in flight shows a spinner in place of its file count; deleting a large playlist clears the selection at once, then removes its files in batches (yielding between each so the UI stays responsive) while its row shows a destructive red spinner until it disappears.

---

## Task 9 — mpv integration (MPVClient, MPVMetalView) ✅

**Status: complete.** The C-to-Swift bridge for libmpv and the Metal rendering surface.

**Deliverables:**
- `MPV/Cmpv/` — a Clang module (`module.modulemap` + `shim.h`) exposing libmpv's C API to Swift as `import Cmpv`. A module rather than an Objective-C bridging header so `@testable import` consumers resolve it cleanly under explicit modules. Discovered via `SWIFT_INCLUDE_PATHS`; the mpv headers it pulls in resolve through `HEADER_SEARCH_PATHS` (the Homebrew mpv keg).
- `MPVEvent.swift` — `nonisolated` `Sendable` enum projecting the mpv events the app consumes (time-pos, duration, pause, file-loaded, end-of-file with reason, shutdown, log).
- `MPVClient.swift` — `nonisolated final class … @unchecked Sendable` wrapper around `mpv_handle`:
  - Serial `DispatchQueue` serializes every mpv API call (`handle` is `nonisolated(unsafe)`).
  - `loadFile(_:startingAt:)`, `play`, `pause`, `stop`, `seek(to:)`, `seek(by:)`, `volume` get/set, `isLooping` get/set.
  - `mpv_observe_property` for time-pos, duration, pause, and eof-reached (the natural-end trigger under `keep-open=yes`).
  - `mpv_set_wakeup_callback` (capture-free C closure) → serial drain → `AsyncStream<MPVEvent>`, single consumer.
  - Audio vs. video via `Configuration` (`--vo=null` vs. `--vo=gpu-next`); optional `wid` passed at init for video embedding.
- `MPVMetalView.swift` — `NSView` subclass backed by a `CAMetalLayer` (EDR enabled); mpv renders into it through Vulkan/MoltenVK via the view's `wid`. Keeps the drawable size in step with backing scale on resize/display change.
- "Bundle mpv" build phase (`Scripts/bundle-mpv.sh`) — copies libmpv and its full dependency closure plus MoltenVK into `Contents/Frameworks/`, rewrites all install names to `@rpath`, writes the MoltenVK Vulkan ICD manifest into `Resources/`, and re-signs each dylib with the app's identity (passes library validation under the hardened runtime). `MPVClient` points the Vulkan loader at the bundled ICD via `VK_DRIVER_FILES`. The app links libmpv from the keg (`-lmpv`, `LIBRARY_SEARCH_PATHS`); the shipped bundle carries its own signed copies and needs no Homebrew at runtime.
- mpv configured with `--vo=gpu-next --gpu-api=vulkan --gpu-context=moltenvk`, `target-colorspace-hint=yes`, `keep-open=yes`, `idle=yes`.

**Testable:** `MPVClientTests` drives a real libmpv instance via mpv's libavfilter virtual sources (`av://lavfi:…`), so no media fixture or subprocess is needed inside the sandboxed test host. 6 tests, all passing:
- MPVClient creates and destroys a handle without crashing.
- Loading a file streams duration and advancing time-pos events.
- Pause command emits `pausedChanged`.
- Seek moves time-pos.
- Volume get/set round-trips.
- Natural end emits `endFile(.eof)` (via eof-reached).

Visual frame rendering is verified once the player views host `MPVMetalView` (Tasks 11–12).

---

## Task 10 — VideoPlaybackEngine and ImagePlaybackEngine  ✅

**Status: complete.** The three `@MainActor @Observable` engines, with a `PlaybackSource` seam for navigation; build clean, 9 `PlaybackEngineTests` passing (plus the `SendableImage` extraction below leaving the 4 `ThumbnailServiceTests` green).

`VideoPlaybackEngine` and `AudioPlaybackEngine` share all logic in a base `MPVPlaybackEngine` — both own one `MPVClient` and expose the same surface, differing only in configuration (video renders into an embedded `MPVMetalView`, created first so its `wid` reaches the client at init; audio uses `--vo=null`). The base consumes the client's `AsyncStream<MPVEvent>` on the main actor and writes its observable state directly: `currentTime`/`duration` from `time-pos`/`duration`, `isPlaying` from `pause`, plus `currentFile`, `isLooping`, and `volume` (0–100, forwarded to the client). `load`/`play`/`pause`/`stop`/`seek(to:)`/`seek(by:)`, `setLooping`/`toggleLoop`, and `advanceToNext`/`returnToPrevious`; an `eof-reached` event advances (looping replays inside mpv, so it never reaches the handler). `load` takes a URL (file path or protocol resource); a string overload drives libavfilter sources in tests.

`ImagePlaybackEngine` has no mpv instance: it decodes the current image off the main actor with `CGImageSource` (`kCGImageSourceShouldAllowFloat` for HDR), publishes `currentImage`, and resets `transform` (an `ImageTransform` of pan offset + zoom scale) to identity on every file change and fit-mode cycle. `cycleFitMode` runs fit → cover → original → fit; an async-`Task` slideshow timer advances on each interval. Pan/zoom gesture wiring lands with `ImagePlayerView` (Task 11).

The `PlaybackSource` protocol (`fileAfter`/`fileBefore`/`url(for:)`) is the seam an engine uses to ask *what* to play next; the `PlaybackCoordinator` conforms in Task 11, tests use a mock. Off-main decode reuses a shared `SendableImage` box extracted from `ThumbnailService` into `Extensions/`.

**Deliverables:**
- `MPVPlaybackEngine.swift` — shared base: owns MPVClient, consumes events, exposes `currentTime`, `duration`, `isPlaying`, `isLooping`, `currentFile`, `volume` as observable state; `load`, `advanceToNext`, `returnToPrevious`, `seek(to:)`, `seek(by:)`, `setLooping`/`toggleLoop`, EOF → advance
- `VideoPlaybackEngine.swift` — base + an embedded `MPVMetalView` (`.video` config)
- `AudioPlaybackEngine.swift` — base with the `--vo=null` `.audio` config
- `ImagePlaybackEngine.swift` — loads images via `CGImageSource` off-main, publishes `currentImage`, `fitMode`, `transform` (+ the `ImageTransform` type), async slideshow timer, `cycleFitMode` (fit → cover → original)
- `PlaybackSource.swift` — navigation/URL-resolution seam the engines hold weakly
- `Extensions/SendableImage.swift` — shared off-main `NSImage` box (was private in `ThumbnailService`)
- Pan/zoom gestures and transform-on-file-change wiring land with the image player view in Task 11

**Testable:**
- mpv engine (via `AudioPlaybackEngine`, window-free): load → `isPlaying` true and `currentTime` advances; `eof-reached` → `advanceToNext` queries the source (mock); loop toggle reaches mpv's `loop-file`; seek moves `currentTime`; `volume` forwards to the client; `stop` clears state
- ImagePlaybackEngine: load image → `currentImage` published, `transform` at identity; fit-mode cycle fit → cover → original → fit and resets the transform; slideshow fires after the interval and advances via the source
- Video engine shares the base implementation (verified through the audio engine); its frame output is verified once the player views host `MPVMetalView` (Tasks 11–12)

---

## Task 11 — PlaybackCoordinator and basic Player mode

Orchestration of engines and the player view shell.

**Deliverables:**
- `PlaybackCoordinator.swift` — owns all three engines, enforces mutual exclusivity (one video XOR image, plus one audio), `play(playlist:)`, `stop(playlist:)`, per-playlist pause/unpause
- Suppression: transient `isSuppressed` flag with `suppress()`/`unsuppress()` — effective playback is `playing && !suppression`, playlist states are untouched and never persisted with it
- Per-playlist Stopped/Playing/Paused mirrored to `Playlist.playbackState`; making another playlist of the same kind active resets the previous one to Stopped
- Advance/previous with wrap-around: past the last file wraps to the first, previous from the first wraps to the last (applies to the filtered sequence when a filter is active); order is never reshuffled by playback
- `PlayerView.swift` — fullscreen container, switches between `VideoPlayerView` and `ImagePlayerView` based on active playlist type
- `VideoPlayerView.swift` — hosts `MPVMetalView` via `NSViewRepresentable`
- `ImagePlayerView.swift` — image display with pan/zoom gestures
- Fullscreen transition: `NSWindow.toggleFullScreen` via NSView bridge on entering/exiting player mode
- `PauseOverlay.swift` — opaque overlay (covers everything) with Unpause and Stop buttons
- `[p]`/`[esc]` activates suppression and shows the pause overlay (halts all playback, including audio); Unpause ends it — Playing playlists continue, Paused playlists stay paused
- Basic `[p]` suppression and `[space]` end-suppression/next

**Testable:**
- PlaybackCoordinator: start video → stop image, start image → stop video
- Start audio → runs in parallel with video/image
- suppress → playback halts on both channels, playlist states unchanged; unsuppress → Playing playlists resume
- Playlist in its own Paused state → unsuppress does not resume it
- Advance past last file wraps to first; previous from first wraps to last; filtered sequence wraps within matches
- Player view enters fullscreen, shows correct content for video vs. image
- Pause overlay appears on `[p]`, Unpause ends suppression, Stop returns to manager

---

## Task 12 — HotkeyRouter and player hotkeys

Global key event handling and routing.

**Deliverables:**
- `HotkeyRouter.swift` — `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`, routing priority chain (text field → esc chain → space → audio holds key context → player/manager). Audio claims key context only when the overlay is fully revealed
- All player hotkeys: space, arrows, `[tab]`/`[arrow up]` (open Files & Tags), `[arrow down]` (close it or reveal Compact audio), `[p]`, `[esc]`, `[delete]`, `[shift]` (fit mode), `[l]` (loop), `[right option]+arrows` (seek ±3s)
- Manager mode hotkeys: `[arrow up/down]` = file-list navigation (standard), `[esc]` (close window), `[delete]` (trash selected). The audio overlay is opened by top-edge hover or the left-panel Audio section — not by arrow keys
- Right Option key detection via `event.keyCode == 61`
- Text input detection: skip hotkey processing when first responder is text field
- The monitor returns `nil` for handled events, which also keeps `[esc]` from triggering the system's default exit-from-fullscreen behavior

**Testable:**
- Synthetic NSEvent with `[space]` when playing → advances to next file
- `[space]` when the pause overlay is shown → ends suppression
- `[p]` → activates suppression, shows the pause overlay
- `[esc]` priority: overlay open → closes overlay, playing → suppresses + pause overlay, suppressed → closes window, Manager → cancels in-progress operation or closes window
- `[l]` → loop toggles
- `[right option]+[arrow right]` → seek +3s
- Text field focused → keys pass through to text field, not hotkey router
- Arrow keys routed to audio only when the audio overlay holds key context (fully revealed); otherwise to the player
- Manager mode: arrow up/down move the file-list selection (not the audio overlay)
- `[tab]` opens Files & Tags

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
- Show pauseOverlay → all other overlays removed (suppression UI covers the whole screen)
- Show audioCompact → closing on hotkey overlay open
- Hover zone fires callback on cursor enter/exit at screen edge
- Animated transitions play correctly (visual verification)

---

## Task 14 — Player overlays: bottom controls, Files & Tags, Playlists

The three major overlays in Player mode.

**Deliverables:**
- `PlaybackControlsBar.swift` — bottom hover: previous, play/pause, stop, next, loop toggle, progress/scrub, volume slider (video); previous, play/pause, stop, next, slideshow toggle, interval selector (image); file list button to toggle Files & Tags. The play/pause button toggles the playlist's own Playing/Paused state — never suppression
- `FilesTagsOverlayView.swift` — slides up from bottom, **simplified single-file** surface (bulk multi-select editing stays in Manager mode). Two sections: file list with filter controls (reuses FilterBar — tag filtering only, no service filters), tag editor (reuses TagEditorView) targeting the **currently active file only**. Per-file interactions: double-click to jump, rename, delete, show in Finder
- `PlaylistsOverlay.swift` — left hover: video and image sections (read-only, no CRUD), collapsed Audio section at the top (opens the extended audio overlay). Selecting a playlist starts playing immediately
- Volume slider per video/audio playlist, persisted
- Progress bar / scrub for video (seeks via MPVClient)
- Slideshow interval selector for image playlists

**Testable:**
- Bottom controls: previous/next advance files, play/pause toggles the playlist's Paused state (suppression untouched), loop toggles, volume changes, scrub seeks
- Files & Tags: file list shows filtered files, double-click jumps player, tag edits rename files
- Playlists overlay: selecting playlist starts it, audio hint opens extended audio
- Controls dismiss on mouse leave (via hover zone)

---

## Task 15 — Audio overlay (compact and extended)

The audio player UI that coexists with video/image playback.

**Deliverables:**
- `AudioOverlayCompact.swift` — current track info, play/pause (sets the audio playlist's own Paused state, separate from suppression), prev/next, stop, progress/scrub, volume, loop toggle
- `AudioOverlayExtended.swift` — expands compact into the manager view for audio playlists: audio-only playlists panel with full management (create, rename, delete, reorder), file list with filtering, tag editor for current track; works during playback
- Audio overlay state machine: Hidden → Compact → Extended via `[arrow down]`, back to Hidden via `[arrow up]`
- Top-edge hover → compact (auto-dismiss on mouse leave)
- `[arrow down]` compact → stays open until explicitly closed
- Audio hotkey context switching: the audio overlay holds key context only once **fully revealed**; then arrows/space/loop/seek target the audio playlist
- Extended file list is a simple vertical list — `[arrow left]`/`[arrow right]` switch tracks, `[arrow up]` progressively closes; arrows do not move a list selection (except when a text field inside is in edit mode)
- Audio playlist selection in extended view → starts playing selected audio playlist
- In Manager mode: Audio section at the top of the playlists panel → opens the extended audio overlay; compact appears only via top-edge hover (never arrow keys, so arrows stay free for file-list navigation)

**Testable:**
- Arrow down from hidden → compact appears, arrow down again → extended
- Arrow up from either → hidden
- Top hover → compact, mouse leave → dismisses
- Audio controls: play/pause/prev/next/stop work on audio engine; pause persists as the playlist's own Paused state
- Extended: selecting audio playlist switches audio playback; create/rename/delete/reorder work for audio playlists
- Tag editing in extended overlay renames audio files

---

## Task 16 — Settings, persistence, and lifecycle

Global settings UI, full state persistence, and app lifecycle handling.

**Deliverables:**
- `SettingsView.swift` — global defaults: slideshow interval, file-position persistence, image fit mode
- Per-playlist preference overrides surfaced in playlist header or context
- File-position persistence: write position every 5s during playback and on file change/stop (when enabled)
- App lifecycle:
  - Launch: restore persisted state, reconstruct PlaybackCoordinator — Playing playlists resume, Paused stay paused (relaunch behaves like reopening the window), restore window frame
  - Window close (not quit): persist state, activate suppression, hide window, keep app running; playlist states unchanged
  - Window reopen (Dock click): lift suppression — Playing playlists continue, Paused stay paused
  - App termination: final persist of all positions and state
- Window frame persistence (debounced on move/resize)
- Stale bookmark handling: inline error on playlist, option to re-select folder

**Testable:**
- Change global default → new playlists use it
- Per-playlist override → overrides global
- File-position persistence: stop and restart → resumes at saved position
- Quit and relaunch → active playlists and window frame restored; Playing playlists resume, Paused stay paused
- Close window → app still running, playback halted (suppressed); reopen → Playing playlists continue
- Stale bookmark → error shown, re-select folder works

---

## Task 17 — Cloud / offline file handling

iCloud/offline awareness: per-file status indicators, on-demand download, and prefetch ahead of playback.

**Deliverables:**
- `CloudFileService.swift` — per-file status (local / in cloud / downloading) via `NSMetadataQuery` scoped to active playlist folders and URL resource values (`.ubiquitousItemDownloadingStatusKey`, `.ubiquitousItemIsDownloadingKey`)
- On-demand download via `FileManager.startDownloadingUbiquitousItem(at:)`
- Prefetch: while the current file plays, request downloads for the next N files in playback order (driven from `PlaybackCoordinator` on each file change)
- Live status published off-main and delivered to `@MainActor` via `AsyncStream`; `CloudStatusBadge.swift` renders "in the cloud" / "downloading" indicators wired into `FileRowView` (list), the gallery, and the Files & Tags overlay
- Playback integration: if the file playback reaches is still in the cloud, request its download immediately; if it cannot be made local in time, advance to the next available file (same rule as missing files)

**Testable:**
- Status mapping: placeholder/evicted → in cloud, actively fetching → downloading, present → local
- Prefetch requests exactly the next N files in playback order on a file change
- On-demand download requested when playback reaches an in-cloud file
- Download timeout → advance to next available file
- Indicators appear/clear as status changes (mock status provider)

---

## Task 18 — Fullscreen polish, window management, and HDR

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

## Task 19 — Accessibility

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
  ├── Task 17 ── Cloud / offline files (after Tasks 6, 8, 11)
  │
  ├── Task 18 ── Fullscreen + HDR (after Tasks 11, 16)
  │
  └── Task 19 ── Accessibility (after all UI tasks)
```

Tasks 5–8 (Manager UI) and Tasks 9–10 (mpv/engines) can be developed in parallel once Task 4 is complete. Task 17 (cloud) depends on the file-list views (6, 8) for indicators and the coordinator (11) for prefetch.
