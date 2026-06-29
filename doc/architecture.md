# Architecture

IMPORTANT!!!: This document covers system design — structure, non-obvious decisions, and rationale. It does not restate behavior (see `features.md`) or mirror the code (see the source). KEEP IT THIS WAY!!! Features not yet built are tracked in `doc/tasks/index.md`; this document describes the design they slot into, not their implementation plans.

## 1. Overview

ShuTaPla is a single-window macOS media player built with SwiftUI and SwiftData. It has two modes of one window — **Manager** (browsing/organizing playlists) and **Player** (fullscreen presentation) — plus an audio layer that plays in parallel.

### Guiding principles

- **Files on disk are the source of truth.** The app never copies or transforms media; playlists are lightweight indexes into the file system, and tags live in filenames.
- **Minimal persistence.** Only ordering, position, and preferences are stored; everything else is derived from disk on each scan.
- **Single-window, modal interface.** Manager and Player are two modes of the same window. Transitions are animated and state-preserving.
- **Parallel audio.** An audio playlist is an independent playback channel that coexists with video/image playback.

---

## 2. Technology stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| UI framework | SwiftUI (macOS 26+) | All views, overlays, controls. AppKit bridges where SwiftUI falls short (split view, hover zones, key monitor, text field). |
| Persistence | SwiftData | Playlist metadata, file lists, preferences, app state. |
| Video/audio playback | mpv (libmpv) | Two independent instances. Handles VP9 WebM, MKV, and all common containers/codecs. |
| Image display | Core Graphics + SwiftUI | `CGImageSource` for loading/thumbnailing; custom view for pan/zoom; EDR-capable layer for HDR. |
| File system | Foundation (FileManager, URL) | Recursive enumeration, rename, trash. Security-scoped bookmarks for persistent folder access. One-shot re-scan on activation — no continuous watching. |
| Remux | FFmpeg (libavformat/libavcodec) | Stream-copy audio strip; same libraries libmpv already links. |
| Concurrency | Swift Concurrency | Default `MainActor` isolation; `actor` for file I/O, `@concurrent` for off-main CPU work (§10). |
| Minimum deployment | macOS 26.4 | |

### mpv integration

mpv is embedded as **libmpv** (`libmpv.dylib`), shipped inside the app bundle's `Frameworks/`. This is the central piece of custom architecture, so the non-obvious constraints are worth stating:

- **Render path.** `--wid` window-embedding is unsupported on macOS (mpv opens its own `NSWindow`), so the app drives the **libmpv OpenGL render API** (`MPV_RENDER_API_TYPE_OPENGL`) instead. `MPVVideoView` (an `NSView`) is backed by `MPVOpenGLLayer` (a `CAOpenGLLayer`); CoreAnimation creates the CGL context lazily, at which point `MPVClient` binds an `mpv_render_context` and registers a render-update callback that drives `draw(inCGLContext:)`. The render API exposes only OpenGL and software targets — no Metal — so libplacebo `gpu-next` and mastering-display luminance metadata are unreachable (accepted). Hardware decode stays on VideoToolbox (`--hwdec=auto-safe`). This is IINA's proven OpenGL approach.
- **C-to-Swift bridge.** libmpv and FFmpeg are exposed as Clang modules (`MPV/Cmpv/`, `FFmpeg/Cffmpeg/`) rather than an Objective-C bridging header, so `@testable import ShuTaPla` resolves them under explicit modules. `MPVClient` is the thin Swift wrapper: it owns the `mpv_handle`, serializes every C call through a dedicated serial `DispatchQueue` (mpv's C API is not thread-safe), and forwards events into an `AsyncStream<MPVEvent>` consumed on `MainActor`.
- **Two instances.** Video and audio use separate `mpv_handle`s with independent state; CoreAudio mixes their output with no extra session configuration.
- **Bundling.** `Scripts/bundle-mpv.sh` copies libmpv's dependency closure into `Contents/Frameworks/`, rewrites install names to `@rpath`, and re-signs each dylib (required under the hardened runtime and for notarization), so the shipped bundle needs no Homebrew at runtime.

---

## 3. Data model (SwiftData)

Five `@Model` entities. `Playlist` owns its `PlaylistFile`s (`@Relationship`, cascade delete). `Tag` is a normalized, shared entity each `PlaylistFile` references many-to-many. `AppStateModel` and `GlobalSettings` are persisted singletons. Embedded preferences/filter/saved-search data are `Codable` value types stored inline, not separate entities.

```
GlobalSettings (singleton)   — default slideshow interval, file-position persistence, image fit mode

Playlist                     — name, folderBookmark (security-scoped), folderPath, mediaType,
 │                             sortOrder, currentFileID, playbackState, createdAt
 ├── preferences: PlaylistPreferences   — volume, slideshow on/interval?, imageFitMode?,
 │                                         filePositionPersistence?, viewMode  (nil = use global)
 ├── filterState: FilterState           — selectedTags, filterMode (and/or), serviceFilter?
 ├── savedSearches: [SavedSearch]        — 10 most recent unique multi-tag searches
 ├── tagFrequency: [String: Int]         — per-playlist tag usage counts (drives dropdown order)
 └── files: [PlaylistFile]
      └── relativePath, fileName, tags: [Tag] (many-to-many), taggingStatusCode (scalar),
          isSkipped, lastPosition?, duration?, sortOrder (shuffled order)

Tag                          — normalizedName (lowercased, @Attribute(.unique)),
                               name (first-seen casing), files: [PlaylistFile] (inverse)

AppStateModel (singleton)    — lastManagedVideo/ImagePlaylistId, audioChannelPlaylistId,
                               managerScopeRaw, windowFrame
```

Singletons use a fetch-or-create pattern (fetch limit 1, insert defaults if absent), cached behind a computed accessor.

### Design decisions

- **`currentFileID` (a UUID), not an index.** Update appends and prunes entries, shifting positions; an ID stays valid through both. Sequence position is recovered from the file's `sortOrder`.
- **Relative paths in `PlaylistFile`** — so moving the folder and refreshing the bookmark keeps file references valid.
- **Security-scoped bookmarks** (`folderBookmark: Data`) — a plain path loses access after restart on sandboxed macOS. The app creates a bookmark on folder selection and starts/stops scoped access around use.
- **Embedded value types** for preferences/filter/saved-searches — avoids a web of one-to-one relationships and makes cascade delete clean.
- **Normalized tags** — each `PlaylistFile` references shared `Tag` entities (deduped by lowercased `normalizedName`, with `name` keeping first-seen casing), so a tag filter is a store predicate over the relationship rather than a per-file Swift comparison. Filenames remain the source of truth: a scan/rename re-parses them through `TagParser` and resolves the strings to `Tag`s via `ModelContext.tags(named:)`, and `PlaylistFile.tagNames` (the chip display) derives from the filename so chip *order* is stable (the relationship is an unordered set). `tagFrequency` still aggregates per-playlist usage counts to drive dropdown ordering.
- **`taggingStatus` as a stored scalar** (`taggingStatusCode: Int`, with a computed `taggingStatus` enum accessor) — a `#Predicate` can't capture the enum, so triage filters (untagged / invalid-tagging) compare the scalar instead.
- **Versioned schema migrations.** `AppMigrationPlan` (a `SchemaMigrationPlan`) declares each `VersionedSchema` and a stage between successive versions.

---

## 4. State management

Two layers: **persisted** SwiftData models (survive launches) and **runtime** `@Observable` classes (transient UI/playback state, reconstructed on launch). Four runtime objects, injected into the SwiftUI environment:

### AppState

`@MainActor @Observable`, holds the SwiftData model context and the playlist slots that drive the UI. Its defining design choices:

- **Three independent slots, kept consistent by explicit load steps, never by deriving one from another:** the **managed slot** (`managedPlaylist`, what all of Manager binds to, any type), the **audio-channel slot** (`audioChannelPlaylist`, persistent), and the **visual channel** (owned by the coordinator). `lastManagedVideo/ImagePlaylist` let a scope switch pre-load each visual type's last-managed playlist; audio's memory *is* the audio-channel slot.
- **Derives filtered file lists store-side as ordered identifiers, resolving only the visible rows.** The filter and current file are persisted per-playlist `@Model` state; the display/playback order is derived by the store from a `#Predicate` over the playlist's effective filter (`Extensions/ModelContext+Sequence.swift`), returning ordered `[PersistentIdentifier]` and counts so a large playlist is never materialized whole. Views iterate the identifiers in a lazy stack/grid and resolve only the on-screen rows; selection, current-file, and next/previous lookups each resolve just the few files they need. Two slots pointing at the same `Playlist` stay consistent for free — no recompute-and-reconcile machinery. The fetches use `includePendingChanges: false`, which the Observation system doesn't track, so a mutation that reshapes membership or order saves before re-deriving and bumps an observed `sequenceVersion` to drive the re-derive.
- **Scope is only the sidebar's type filter**, not selection/filter/routing state (`managerScope: .image | .video | .audio`). `switchScope(to:)` sets the scope and pre-loads that scope's remembered playlist.
- **One converged `select(_:)`** loads the picked playlist into the managed slot (and, for audio, into the audio channel, stopping whichever was live). Overlays keep play-on-select variants (`selectVisualPlaylistInPlayer`, `selectAudioPlaylist`).
- **Filter edits write to the target playlist's persisted `filterState`**; surfaces re-derive. The one explicit side effect is the live-channel reconcile when an edit drops the file an engine is on.
- **Centralizes scoped folder access** for every file mutation (`beginFolderAccess(to:)`), including the stale/denied-bookmark re-grant prompt, and exposes optimistic-progress state the sidebar renders as spinners (scanning / re-scanning / deleting).

### PlaybackCoordinator

`@MainActor @Observable`. Owns both mpv instances and the image slideshow timer, and is the central authority for playback. Enforces the concurrency rules (at most one video XOR image; at most one audio in parallel; stopping one channel never affects the other) and owns the single transient **suppression** flag (`effective playback = playing && !suppression`; never persisted).

When a filter, re-scan, or deletion reshapes a sequence, `reconcileVisualSelection()` / `reconcileAudioSelection()` jump the engine to the first surviving file or clear it. Because loading a file auto-starts it, a jump re-suspends a channel that should stay halted. Deleting a playing playlist stops its channel first, so the engine never references models about to be freed.

### OverlayManager

`@MainActor @Observable`. Tracks Player-mode overlay visibility as an enum **set** (not a stack — overlays don't nest arbitrarily) and enforces the spec's exclusivity rules. Compact and Expanded audio are two states of one `AudioOverlay` view. It also owns **key context** — which target (visual player vs. Audio Overlay) receives arrow/space/loop/seek keys — claimed by the Audio Overlay only once fully revealed, returned to the player when it closes to Hidden. The router reads key context from here so both layers agree on who owns the keys.

### HotkeyRouter

Owns an app-wide `NSEvent` monitor (§9) and routes each key by: text-field-focused → swallow; `[esc]` → priority chain; Audio Overlay holds key context → audio controls; else → the player or manager table.

The per-playlist state machine (Stopped/Playing/Paused) and suppression semantics are specified in `features.md`; the coordinator mirrors that state at runtime.

---

## 5. Service layer

Services hold UI-independent logic, are injected into state objects (not views), and are protocol-based for mock injection in tests (§16). Each is summarized by responsibility; signatures live in the source.

- **FileSystemService** (`actor`) — resolves bookmarks and manages access sessions; recursively enumerates and classifies a folder by extension; determines the dominant media type or flags Mixed; detects new/removed files for Update. Disk I/O is serialized through the actor (a rename must not interleave with a scan). It also derives each listed file's filename tags (via `TagParser`) into the `ScannedFile` values it returns, so parsing happens off-main. Classification uses static extension-to-type sets; a type is auto-assigned when ≥ 80% of recognized files are of it, otherwise the folder is **Mixed** and the user is prompted — there is no second threshold.

- **PlaylistScanActor** (`@ModelActor`) — runs the Update reconcile off the main actor on its **own** `ModelContext`: against the `FileSystemService` listing it prunes vanished files, appends new ones, writes each surviving file's diverged tag/status fields, rebuilds `tagFrequency`, saves, and batch-deletes globally-orphaned `Tag`s — the entire derived write, never on the main context. Models aren't `Sendable` across contexts, so the boundary is value types: the playlist's app `UUID` in, a `removedFileIDs`/`changed` summary out (it resolves the playlist by that `UUID`, since a still-temporary `PersistentIdentifier` would trap). This keeps the per-rescan derive/diff/write pass off the main actor so activating a large playlist stays instant.

- **TagParser** — pure functions (filename ↔ tags), heavily unit-tested. Parses the single bracket group, detecting **invalid tagging** (more than one pair, nesting, or any token that isn't a valid tag: `[a-zA-Z0-9_]{3,}`); a single unmatched bracket in prose is ignored, not invalid. Tags are lowercased for matching with on-disk casing preserved. Builds new filenames for add/remove/rename, substituting a placeholder base when an edit would otherwise leave an empty name.

- **PlaybackEngines** — `VideoPlaybackEngine` and `AudioPlaybackEngine` each own one `MPVClient`; `ImagePlaybackEngine` is a timer-based slideshow driver with no mpv. Each is `@MainActor @Observable`, exposing time/duration/isPlaying/isLooping for direct SwiftUI observation. Each `AsyncStream<MPVEvent>` has exactly one consumer — the owning engine — which updates its own observable state on `MainActor`; the coordinator observes those. On `eof-reached`, looping replays via mpv's `loop-file`, otherwise the engine advances to the next file in `sortOrder` (the coordinator decides the target).

- **ThumbnailService** (`@MainActor @Observable`) — lazy thumbnails over a two-tier cache (in-memory `NSCache` over an on-disk PNG cache keyed by `relativePath + mod-date + size`). The `@MainActor` entry reads the model, then `@concurrent` workers resolve the bookmark, render, and return a ready-to-draw `NSImage` (decoded off-main so scrolling never blocks on a draw-time decode). A synchronous `cachedThumbnail` lookup avoids a placeholder flash for already-cached cells. Image frames come from `CGImageSource`; video frames from `AVAssetImageGenerator`, **falling back to `MPVThumbnailer`** for containers AVFoundation can't demux (webm/mkv). Generation also carries the file's running **duration** back with the frame, so the gallery's length badge appears with the thumbnail rather than as a second pass.

- **MPVThumbnailer** — stateless libmpv fallback. Each call spins a short-lived windowless mpv instance (`vo=image`), seeks 10% in, writes one PNG, and tears down — owning a fresh handle, never touching the playback engines' `MPVClient`. Calls are serialized on one background-QoS queue with a per-call deadline. Also exposes `duration(at:)` (loads just far enough to read the demuxer's duration, decoding nothing).

- **DurationService** (`@MainActor @Observable`) — the standalone running-time path for surfaces with no thumbnail (file-list rows, cache-hit gallery cells). Media-type-agnostic. Returns `PlaylistFile.duration` when known, otherwise an off-main worker reads it (`AVURLAsset.load(.duration)`, or `MPVThumbnailer.duration` for webm/mkv) and writes it back, so the value is instant on later displays and across launches.

- **AudioStripper** — backs the **Remove Audio** action by remuxing with libavformat: copies the video stream's `AVCodecParameters` into a new output context and forwards only video packets (no decode/re-encode — fast, lossless, works for every container the player opens, including webm/mkv). Orchestrated by `AppState.stripAudio(from:)` mirroring the delete flow: under one scoped session it remuxes to a hidden sibling, trashes the original as a recoverable backup, and swaps the result in (reloading a video currently on screen at its position). A per-row spinner runs while it works.

- **BookmarkService** — creates/resolves security-scoped bookmarks, reference-counts concurrent users of the same folder (e.g. an audio and a video playlist over one folder), and throws on stale/denied bookmarks so `AppState.beginFolderAccess(to:)` can re-prompt and refresh.

Cloud/offline file handling (`CloudFileService`, status badges, prefetch) is a planned service — see Task 18 in `tasks/index.md`.

---

## 6. UI architecture

### Window model

A single `WindowGroup` whose content switches between `WelcomeView` / `ManagerView` / `PlayerView` on `appState.mode`, plus a `Settings` scene. The default "New Window" command is removed (`CommandGroup(replacing: .newItem) {}`) to enforce single-window. Entering Player mode toggles `NSWindow` fullscreen in step with the view switch; Stop reverses both. Closing the window hides it but keeps the app running (Dock reopen restores prior state).

### Manager shell

The shell is an AppKit `NSSplitViewController` (`ManagerSplitScene`) hosting three SwiftUI panes (`PlaylistSidebar`, `PlaylistCenterView`, `TagSidebar`) in `NSHostingController`s, bridged into the `WindowGroup` via `NSViewControllerRepresentable`. AppKit is used because SwiftUI can't give a custom `NSToolbar` with regions aligned over the split panes: `NSTrackingSeparatorToolbarItem`s pinned to the dividers bound a leading region (scope tabs + New Playlist `+`), a center region (managed playlist name + type actions), and a trailing region (tag controls). `ManagerChrome` (an `@Observable`: `sidebarCollapsed`, `inspectorVisible`, `managingTags`) is the shared source of truth both controller and panes read. Scope tabs are a custom toggle (`ScopeTabButton`) rather than a segmented `Picker` so a click on the already-active scope can collapse the sidebar. Sidebar rows come from a `@Query` in the view (kept out of `@Observable` classes, where `@Query` conflicts with the macro).

Quick playlist switching in Player mode lives in the overlays' `LibrarySurface` selector (a pure switcher — no create/rename/delete/reorder), not a separate panel; full management stays in the sidebar.

### Player overlays

Overlays are SwiftUI views composed via `.overlay()` / `.transition()` on `PlayerView`, shown/hidden with `withAnimation` driven by `OverlayManager` state. **Hover zones** use `NSTrackingArea` (via an NSView bridge), not SwiftUI `.onHover`, which doesn't fire at the screen edge in fullscreen. Exclusivity is enforced centrally in `OverlayManager` when an overlay is shown (Expanded audio is exclusive; the Visual Overlay suppresses the bottom controls' hover; Compact audio yields only to Expanded audio); the rules themselves are specified in `features.md`.

---

## 7. File system and tags

### Folder scanning pipeline

```
pick folder → create bookmark → recursive enumerate → classify by extension
   → count by type (≥80% one type auto-assign, else prompt) → keep chosen type
   (others retained as isSkipped entries) → parse tags → Fisher-Yates shuffle
   → persist Playlist + PlaylistFiles → build tagFrequency cache
```

Update and Reshuffle both re-read disk on a background `Task` with a "sync in progress" indicator; their differing semantics (append/prune/preserve vs. full reshuffle/reset) are in `features.md`. Update runs automatically when a playlist becomes active. Its reconcile runs and saves entirely on `PlaylistScanActor`'s own `ModelContext` (§5); because a sibling-context save isn't merged into the main context's registered objects, the main actor then **refaults the held playlist** (a fetch that updates the same instance in place) so the tag UI reading `playlist.tagFrequency` is current, and bumps `sequenceVersion` so the store-side file lists re-fetch.

### Tag editing

A tag edit goes: `TagParser` builds the new filename → `FileSystemService.renameFile` (synchronous, atomic POSIX rename, same directory) → on success update `fileName`/`relativePath`/`tags` and `tagFrequency`, and reload the file in mpv if it's playing. On failure (collision, permission, read-only/offline volume, trash failure) the file and its model entry are left untouched and a non-blocking notification is surfaced — the graceful-failure rule for **all** file mutations (edits, renames, deletes, playlist-wide ops). Playlist-wide rename/remove iterate matching files, renaming each on disk one at a time and updating models only for successes, collecting an error list surfaced after the batch.

### Shared tag control

`TagTokenField` is the one multiselect-with-autocomplete control behind both the tag editor and the filter bar. Selected tags are removable chips; typing filters a floating dropdown ranked by match (exact → prefix → substring) then `tagFrequency`, overlaid above following controls (each call site raises its `zIndex`). The static `options(query:knownTags:selected:allowsCreate:)` computes the ranking and is unit-tested directly. `TagEditorView` instantiates it with `allowsCreate: true` (adds to the file); `FilterBar` with `allowsCreate: false` (search-to-select into `filterState`).

The text input is a borderless `NSTextField` wrapper (`TokenTextField`), not a SwiftUI `TextField`: focus, the caret, and the caret-edge key commands (`delete`/arrows/`return`/`esc` via `doCommandBy:`) come straight from AppKit — the layer SwiftUI's `@FocusState`/`onKeyPress` miss on an empty field. The field is inserted only on click (never auto-focuses), and while focused runs a local `leftMouseDown` monitor that resigns focus on an outside click *without* consuming the event, so the same click also lands on whatever it hit.

For an `.invalid`-tagging file, `TagEditorView` disables the chip editor and shows an "invalid tag syntax" message plus a plain rename field (chip editing would risk dropping the malformed bracket content); it re-enables once the name parses clean.

---

## 8. Media playback

`PlaybackCoordinator` (§4) is the authority. `play(playlist:)` routes by media type, stopping the opposite visual engine (video XOR image) and leaving the audio channel untouched. Each engine wraps its medium behind an `@MainActor @Observable` surface:

- **Video** — `VideoPlaybackEngine` owns an `MPVClient` and an `MPVVideoView`; mpv renders through the OpenGL render API (§2). Consumes the mpv event stream (time-pos → progress, `eof-reached` → advance or loop), seeks ±3s relatively, tracks the current file by `currentFileID` so filter toggles and Update prune/append never lose position.
- **Image** — `ImagePlaybackEngine` loads via `CGImageSource`, holds fit mode and a pan/zoom transform (reset on file change), and drives a slideshow `Timer`. Pan/zoom uses SwiftUI `MagnifyGesture`/`DragGesture` plus a scroll-wheel bridge.
- **Audio** — `AudioPlaybackEngine` owns a second independent `MPVClient` configured `--vo=null`. Its `volume` is independent of system and video volume; CoreAudio mixes the two instances.

HDR video passes through to EDR displays via the `MPVOpenGLLayer` (float backbuffer, `wantsExtendedDynamicRangeContent`, extended-sRGB colorspace) paired with mpv's `--target-colorspace-hint=yes`. HDR image output is a planned extension (Task 19).

---

## 9. Hotkey system

Key events are captured app-wide via `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`, chosen over SwiftUI `.onKeyPress` because the player runs fullscreen where view focus is fragile, and because the router must decide routing before any view sees the event. Returning `nil` consumes the event — this is also what keeps `[esc]` and arrows from triggering the system's default fullscreen-exit, so the esc priority chain stays in control.

**Consumption semantics.** The monitor returns `handle(event)`, which yields `nil` to consume or the event to pass through — deliberately **no `?? event` fallback**, which would resurrect every consumed key and ring the system beep. `handle` passes through any Command/Control combination (so menu shortcuts are never hijacked) and everything while a text field is first responder, and in Player mode swallows any leftover bare key (the immersive player has nowhere for a stray key to go).

The routing priority itself — the esc chain, `[space]`, key-context, and the player vs. manager tables — is specified in `features.md`; the router implements it reading key context from `OverlayManager` (§4). `[right option] + arrow` is detected by `keyCode == 61`; `[shift]` for fit mode by `modifierFlags.contains(.shift)`.

---

## 10. Concurrency model

Swift 6 language mode with **default actor isolation set to `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Approachable Concurrency — the Xcode 26 defaults). Everything is `MainActor`-isolated unless declared otherwise; the explicit `@MainActor` annotations in this document are therefore redundant but kept for clarity. Off-main work is opted into explicitly: the `FileSystemService` actor, the `PlaylistScanActor` (a `@ModelActor` with its own `ModelContext`), the `MPVClient` serial queue, and `@concurrent` functions.

The load-bearing subtlety: **under Approachable Concurrency a plain `nonisolated async` function runs on the caller's actor**, so a CPU-bound helper awaited from the main actor stays on the main thread unless marked `@concurrent` (as the thumbnail generation/decode workers are). `nonisolated` alone does not leave the main actor here.

Results from background work are delivered back to `MainActor` to touch SwiftData and UI — an `await fileSystemService.scanFolder(...)` hops off via actor isolation and returns on `MainActor`. Folder scans, auto-update, per-cell thumbnail generation (cancellable on scroll), and batch tag operations run as structured `Task`s; tag-edit renames are awaited inline (fast enough to feel synchronous).

---

## 11. Persistence and lifecycle

| Data | Storage | When written |
|------|---------|-------------|
| Playlists, files, preferences | SwiftData | On mutation (auto-save) |
| Active playlist IDs, Manager scope | SwiftData (`AppStateModel`) | On activation/deactivation, scope change |
| Per-playlist playback state | SwiftData (`Playlist`) | On Stopped/Playing/Paused transition (suppression is runtime-only) |
| Last-played file (`currentFileID`) | SwiftData (`Playlist`) | On file advance |
| File position within file | SwiftData (`PlaylistFile`) | Always for the live Visual/Audio Channel Playlists (lifecycle resume, cleared on Stop); for any other entry into a file only when `filePositionPersistence` is on |
| Window frame | SwiftData (`AppStateModel`) | On move/resize (debounced) |
| Security-scoped bookmarks | SwiftData (`Playlist`) | On creation |
| Thumbnail cache | File system (Caches dir) | On generation |

Launch reconstructs the runtime objects from persisted state (Playing playlists resume, Paused stay paused — relaunch behaves like reopening the window). On a file mutation against a stale bookmark, `AppState.beginFolderAccess(to:)` prompts to relocate the folder and refreshes the bookmark.

---

## 12. Error handling strategy

The unifying rules (behavior detailed in `features.md`):

- **File mutations never lose data.** A failed rename/delete/trash (collision, permission, read-only/offline volume, disk full) leaves the file and model untouched and surfaces a non-blocking notification — no partial model change.
- **Missing/unplayable files degrade gracefully.** A file that vanishes or won't decode is skipped, pruned from the playlist on the next scan, and playback advances to the next available file. An emptied playable sequence shows the "no files match" state (visual) or returns the channel to Stopped (audio).
- **Lost folder access re-prompts.** A stale bookmark triggers the relocate-and-refresh flow on the next mutation; persistent inaccessibility surfaces an inline error on the playlist.

---

## 13. Accessibility

VoiceOver and macOS accessibility support (semantic fonts/colors, `Button` over `onTapGesture`, accessibility labels/values on rows, chips, panels, sliders, `@ScaledMetric` spacing) is Task 20 in `tasks/index.md`.

---

## 14. Directory structure

Repo-root Xcode file-system-synchronized groups: `ShuTaPla/` (app source), `ShuTaPlaTests/`, `ShuTaPlaUITests/`, `doc/`. Within `ShuTaPla/`:

```
App/         ShuTaPlaApp (@main, scene, container), AppConstants (extension maps, thresholds)
Models/      Playlist, PlaylistFile, Tag, AppStateModel, GlobalSettings (@Model);
             PlaylistPreferences, FilterState, SavedSearch (Codable); Enums
State/       AppState, PlaybackCoordinator, OverlayManager, HotkeyRouter
Services/    FileSystemService (actor), PlaylistScanActor (@ModelActor), TagParser,
             BookmarkService, ThumbnailService, MPVThumbnailer, AudioStripper, DurationService
MPV/         MPVClient, MPVVideoView (NSView + CAOpenGLLayer), MPVEvent, Cmpv/ (Clang module)
FFmpeg/      Cffmpeg/ (Clang module)
Engines/     VideoPlaybackEngine, AudioPlaybackEngine, ImagePlaybackEngine
Views/
  Welcome/   WelcomeView
  Manager/   ManagerView, ManagerSplitScene, PlaylistSidebar, PlaylistCenterView,
             FileCollectionView, FileListView, FileGalleryView, FilterBar,
             PlaylistTagsView, TagSidebar
  Player/    PlayerView, VideoPlayerView, ImagePlayerView, PauseOverlay, PlaybackControlsBar
  Audio/     AudioInlet, AudioOverlay
  Shared/    TagEditorView, TagTokenField, FlowLayout, VisualOverlay, LibrarySurface,
             HoverZone, ControlButtonStyle, FileSelection, FileRowView
  Settings/  SettingsView
Extensions/  URL+MediaType, Array+Move, NSWindow+Fullscreen
Resources/   Assets.xcassets
```

Tests (`ShuTaPlaTests/`, Swift Testing) cover `TagParser`, `FileSystemService`, `PlaybackCoordinator`, `OverlayManager`, and `HotkeyRouter`.

---

## 15. Key design decisions and rationale

- **SwiftData over plain files or Core Data** — native SwiftUI observation, less boilerplate for reactive updates, and out-of-the-box lazy loading/indexing for playlists of thousands of files.
- **mpv over AVPlayer** — AVPlayer can't decode VP9/AV1 or demux MKV; the library includes VP9 WebM. mpv (via ffmpeg) handles virtually every format. The cost — bundling libmpv + ffmpeg (~40–50 MB), the C bridge, signing the dylibs — is worth it for a player whose core job is playing files.
- **NSEvent monitor over `.onKeyPress`** — view focus is fragile in fullscreen and across overlay changes; a window-wide monitor enables the priority routing without focus worries.
- **NSTrackingArea over `.onHover` for edges** — `.onHover` never fires at the screen edge in fullscreen (no view to "enter"); a thin tracking rect at each edge detects it.
- **Security-scoped bookmarks** — the sandbox requires them to persist folder access across launches. The app declares read-write user-selected access (`ENABLE_USER_SELECTED_FILES = readwrite`) since tag edits/renames/trashing write to the folders.
- **Single actor for file I/O** — operations on the same folder must not interleave; one actor serializes disk access without explicit locking.
- **Embedded value types for preferences/filters** — separate entities would create a web of one-to-one relationships complicating queries and cascade; Codable structs keep the model flat.

---

## 16. Testing strategy

Unit and integration tests use **Swift Testing** (`import Testing`); `ShuTaPlaUITests` stays on XCTest (`XCUIApplication` requires it), with UI coverage from manual testing and Previews. Services are accessed through `Sendable` protocols with `async` requirements, so an actor conformer (`FileSystemService`) and a plain struct mock both satisfy them — letting tests inject canned results.

`TagParser` is covered by parameterized `@Test(arguments:)` rows; `FileSystemService` by integration tests over temp directories; `PlaybackCoordinator`/`OverlayManager`/`HotkeyRouter` by unit tests asserting state transitions, exclusivity, key-context transfer, and routing priority. The trap classes that can hang a test run (orphaned `ModelContext`, async work outliving an in-memory container, real libmpv teardown races, `inout self` closures in `mutating` extensions) and how to write around each are documented in `CLAUDE.md`.

---

## 17. Future considerations (out of scope for v1)

Architectural hooks, not planned features — the design accommodates them without structural change:

- **Advanced filter expressions** (per-tag AND/OR, grouped) — `FilterState` can grow from a flat tag list to a node tree.
- **File system watching** — the one-shot re-scan on activation can extend to FSEvents/DispatchSource monitoring.
- **Keyboard shortcut customization** — the `HotkeyRouter` action mapping can be made configurable.
