# Architecture

## 1. Overview

ShuTaPla is a single-window macOS media player built with SwiftUI and SwiftData. It operates in two major modes — **Manager** (browsing/organizing playlists) and **Player** (fullscreen media presentation) — with an independent audio layer that runs in parallel.

### Guiding principles

- **Files on disk are the source of truth.** The app never copies, moves, or transforms media. Playlists are lightweight indexes into the file system.
- **Minimal persistence.** Only ordering, position, and user preferences are stored. Everything else is derived from disk on each scan.
- **Single-window, modal interface.** Manager and Player are two modes of the same window, not separate windows. Transitions are animated and state-preserving.
- **Parallel audio.** An audio playlist is an independent playback channel that coexists with video/image playback without interference.

---

## 2. Technology stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| UI framework | SwiftUI | macOS 26+. All views, overlays, and controls. |
| Persistence | SwiftData | Playlist metadata, file lists, preferences, app state. |
| Video playback | mpv (libmpv) | Embedded as a dynamic library. Renders through the libmpv OpenGL render API into an app-owned `CAOpenGLLayer`-backed NSView. Handles VP9 WebM, MKV, and all common containers/codecs. |
| Audio playback | mpv (libmpv) | Second independent mpv instance for audio. Mixed output at the OS level (macOS CoreAudio handles concurrent output devices). |
| Image display | Core Graphics + SwiftUI | CGImageSource for efficient loading/thumbnailing. Custom view for pan/zoom. HDR via NSImage with EDR support. |
| File system | Foundation (FileManager, URL) | Recursive enumeration, rename, trash. Security-scoped bookmarks for persistent folder access. |
| File re-scan | Foundation (FileManager) | One-shot re-scan on playlist activation to detect new/removed files. No continuous watching in v1. |
| Cloud files | Foundation (NSMetadataQuery, FileManager ubiquitous APIs) | Detect iCloud/offline placeholder state per file; request on-demand downloads and prefetch the next files in playback order. |
| Concurrency | Swift Concurrency | async/await, actors for serialized file I/O, TaskGroups for parallel thumbnail generation. |
| Minimum deployment | macOS 26.4 | |

### mpv integration approach

mpv is embedded as **libmpv** (dynamic library, `libmpv.dylib`) built via Homebrew or from source with `--enable-libmpv-shared`. The app ships the dylib inside the app bundle's `Frameworks/` directory.

**Rendering pipeline**: mpv is configured with `--vo=libmpv` and the app drives rendering through the **libmpv OpenGL render API** (`mpv_render_context_create` with `MPV_RENDER_API_TYPE_OPENGL`). This is the only way mpv embeds on macOS: `--wid` window-embedding is unsupported here (mpv otherwise opens its own `NSWindow`), and the render API exposes only OpenGL and software targets — no Metal/Vulkan type. The `MPVVideoView` (an `NSView` subclass) is backed by an `MPVOpenGLLayer` (a `CAOpenGLLayer`); CoreAnimation creates the layer's CGL context lazily, at which point `MPVClient.createRenderContext` binds an `mpv_render_context` to it and registers a render-update callback. When mpv signals a new frame the callback marks the layer for display, and the layer's `draw(inCGLContext:…)` calls `mpv_render_context_render` into the framebuffer CoreAnimation bound, then `mpv_render_context_report_swap`. The NSView is bridged into SwiftUI via `NSViewRepresentable`. OpenGL is deprecated on macOS but still present (it runs over Metal on Apple Silicon); the render API uses mpv's `gpu` renderer rather than libplacebo `gpu-next`, which libmpv does not expose. Hardware decode stays on VideoToolbox (`--hwdec=auto-safe`).

**C-to-Swift bridge**: libmpv's C API is exposed to Swift as a Clang module (`MPV/Cmpv/`: a `module.modulemap` over a `shim.h` that includes `<mpv/client.h>`/`<mpv/render.h>`/`<mpv/render_gl.h>`), imported as `import Cmpv`. A module rather than an Objective-C bridging header so `@testable import ShuTaPla` resolves it cleanly under Xcode's explicit modules. The FFmpeg libraries are bridged the same way (`FFmpeg/Cffmpeg/`, imported as `import Cffmpeg`) for `AudioStripper`'s remux. The thin Swift wrapper (`MPVClient`) over libmpv:
- Manages the `mpv_handle` lifecycle (create/destroy).
- Serializes all `mpv_command`/`mpv_set_property`/`mpv_observe_property` calls through a dedicated serial `DispatchQueue`. mpv's C API is not thread-safe — all calls to a given `mpv_handle` must be serialized.
- Sends commands via `mpv_command_async` (load file, seek, pause, etc.).
- Observes properties via `mpv_observe_property` (time-pos, duration, pause, eof-reached, etc.).
- Receives events via a callback that posts to an `AsyncStream<MPVEvent>`, consumed on MainActor for UI updates.

**Two-instance architecture**: Video and audio use **separate `mpv_handle` instances**. Each instance has independent state (volume, position, pause). macOS CoreAudio automatically mixes the output of both instances — no additional audio session configuration needed.

**Build and distribution**: A "Bundle mpv" build phase (`Scripts/bundle-mpv.sh`) copies libmpv and its dependency closure (ffmpeg, libplacebo, …) into `Contents/Frameworks/`, rewrites every install name to `@rpath` so the app loads them from the bundle rather than `/opt/homebrew`, and re-signs each dylib with the app's identity (required for library validation under the hardened runtime, and for notarization). The OpenGL render path needs no Vulkan loader, MoltenVK, or ICD manifest, so none are bundled. At build time the app links libmpv and the FFmpeg libraries it uses directly (`-lmpv -lavformat -lavcodec -lavutil` + `LIBRARY_SEARCH_PATHS`) from the Homebrew kegs; the FFmpeg dylibs are already in libmpv's bundled closure, and the script rewrites every Homebrew reference in the executable to `@rpath`, so the shipped bundle is self-contained and needs no Homebrew at runtime.

**HDR**: mpv handles HDR tone-mapping natively. The `MPVOpenGLLayer` opts into EDR with a floating-point backbuffer, `wantsExtendedDynamicRangeContent = true`, and an extended-sRGB colorspace, paired with mpv's `--target-colorspace-hint=yes`, so HDR clips pass through to EDR-capable displays. Mastering-display luminance metadata (`edrMetadata`) requires a Metal layer, which the libmpv render API cannot target — an accepted limitation. This is IINA's proven OpenGL HDR approach.

---

## 3. Data model (SwiftData)

### Entity relationship diagram

```
GlobalSettings (singleton)
 ├── defaultSlideshowInterval: TimeInterval
 ├── defaultFilePositionPersistence: Bool
 └── defaultImageFitMode: ImageFitMode

Playlist
 ├── id: UUID
 ├── name: String
 ├── folderBookmark: Data              // security-scoped bookmark
 ├── folderPath: String                // display-only, not used for access
 ├── mediaType: MediaType              // .video | .image | .audio
 ├── sortOrder: Int                    // user-defined ordering in sidebar
 ├── currentFileID: UUID?              // current/last-played file — an ID stays valid through Update prune/append, an index does not
 ├── playbackState: PlaybackState      // .stopped | .playing | .paused — persisted per-playlist state
 ├── createdAt: Date
 │
 ├── preferences: PlaylistPreferences  // embedded value, not separate entity
 │    ├── volume: Float                // 0.0–1.0
 │    ├── slideshowEnabled: Bool
 │    ├── slideshowInterval: TimeInterval?   // nil = use global default
 │    ├── imageFitMode: ImageFitMode?        // nil = use global default
 │    ├── filePositionPersistence: Bool?      // nil = use global default
 │    └── viewMode: ViewMode                 // .list | .gallery
 │
 ├── filterState: FilterState          // embedded value — persisted per-playlist filter
 │    ├── selectedTags: [String]
 │    ├── filterMode: FilterMode       // .and | .or
 │    └── serviceFilter: ServiceFilter? // .untagged | .invalidTagging | .skipped; nil = tag filter active
 │
 ├── savedSearches: [SavedSearch]      // 10 most recent unique multi-tag searches;
 │    └── each: { tags: [String], mode: FilterMode }   // re-applying an existing one moves it to the top
 │
 ├── tagFrequency: [String: Int]       // per-playlist tag usage counts
 │
 └── files: [PlaylistFile]             // @Relationship, cascade delete
      ├── id: UUID
      ├── relativePath: String         // relative to playlist folder
      ├── fileName: String             // just the filename component
      ├── tags: [String]               // parsed from filename, cached
      ├── taggingStatus: TaggingStatus // .valid | .untagged | .invalid
      ├── isSkipped: Bool              // unsupported / other-media-type file; kept for the skipped-files filter, never played or shuffled in
      ├── lastPosition: TimeInterval?  // for file-position persistence
      ├── duration: TimeInterval?      // running time, extracted on first display; nil for images
      ├── sortOrder: Int               // shuffled order within playlist
      └── (runtime) cloudStatus: CloudStatus  // not persisted — derived from disk each scan/observation

AppStateModel (singleton, persisted)
 ├── lastManagedVideoPlaylistId: UUID?   // video scope's remembered playlist — pre-loaded into the managed slot on a switch to video
 ├── lastManagedImagePlaylistId: UUID?   // image scope's remembered playlist — same, for image
 ├── audioChannelPlaylistId: UUID?      // the audio-channel playlist (persistent); doubles as audio's remembered managed playlist
 ├── managerScopeRaw: String?           // persisted Manager scope: "image" | "video" | "audio"
 └── windowFrame: Data?                 // encoded NSRect
```

**Singleton pattern**: SwiftData has no built-in singleton mechanism. `AppStateModel` and `GlobalSettings` use a fetch-or-create pattern: on launch, fetch with `FetchDescriptor` (limit 1). If no result, insert a new instance with defaults. All access goes through a computed property on the app's container or state object that caches the fetched instance.

### Design decisions

- **PlaylistPreferences as an embedded value type** (Swift `Codable` struct stored as a SwiftData property — SwiftData automatically encodes/decodes Codable types to JSON), not a separate SwiftData entity. Avoids join overhead and simplifies cascade — deleting a playlist deletes its preferences automatically.
- **FilterState and SavedSearch as embedded values** for the same reason.
- **Security-scoped bookmarks** (`folderBookmark: Data`) are essential. A plain file path loses access after app restart on sandboxed macOS. On folder selection, the app creates a bookmark; on access, it resolves the bookmark and starts/stops security-scoped access.
- **Relative paths in PlaylistFile** — stored relative to the playlist's root folder so that if the folder is moved and the bookmark is updated, file references remain valid.
- **Tag data is denormalized** — tags are stored both per-file (as parsed arrays) and aggregated per-playlist (as `tagFrequency`). The per-file data is the cache; the per-playlist frequency drives UI ordering in filter/editor dropdowns.
- **`currentFileID` instead of an index** — Update appends and prunes entries, which shifts positions; an ID reference stays valid through both. Sequence position is recovered via the file's `sortOrder`.

### Enums

```swift
enum MediaType: String, Codable, Sendable { case video, image, audio }
enum ImageFitMode: String, Codable, Sendable { case fit, cover, original }
enum ViewMode: String, Codable, Sendable { case list, gallery }
enum FilterMode: String, Codable, Sendable { case and, or }
enum TaggingStatus: String, Codable, Sendable { case valid, untagged, invalid }
enum PlaybackState: String, Codable, Sendable { case stopped, playing, paused }
enum CloudStatus: String, Sendable { case local, inCloud, downloading }     // runtime only, not persisted
enum ServiceFilter: String, Codable, Sendable { case untagged, invalidTagging, skipped }  // persisted on FilterState
```

### Sendable conformance

Types that cross isolation boundaries (e.g., from `FileSystemService` to `@MainActor`) must be `Sendable`:

- **`ScanResult`, `UpdateDelta`, `TagParseResult`** — value types returned from `FileSystemService`. Conform to `Sendable` naturally as structs with Sendable fields.
- **`MPVEvent`** — enum with value-type payloads (TimeInterval, Bool). Conforms to `Sendable`. Crosses from the MPVClient serial queue to MainActor via AsyncStream.
- **`MPVClient`** — wraps an `OpaquePointer` (mpv_handle) and a serial `DispatchQueue`. Marked `@unchecked Sendable` with documented safety invariant: all access to `handle` is serialized through `queue`.
- **All Codable embedded structs** (`PlaylistPreferences`, `FilterState`, `SavedSearch`) — pure value types, implicitly `Sendable`.
- **All enums** — `RawRepresentable` with `String` raw values, implicitly `Sendable`.

---

## 4. State management

The app uses two layers of state:

1. **Persisted state** — SwiftData models (playlists, files, preferences, app state). Survives launches.
2. **Runtime state** — `@Observable` classes that hold transient UI and playback state. Reconstructed on launch from persisted state.

### Observable state objects

```
                  ┌──────────────────────────┐
                  │      AppStateModel       │  (persisted singleton)
                  │ lastManagedVideoPlaylistId│
                  │ lastManagedImagePlaylistId│
                  │ audioChannelPlaylistId   │
                  │ managerScopeRaw          │
                  └────────────┬─────────────┘
                               │ references
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────┐
   │ PlaybackCoord.   │ │   OverlayMgr     │ │ HotkeyRouter │
   │                  │ │                  │ │              │
   │ videoEngine      │ │ active:          │ │ resolves key │
   │ imageEngine      │ │   Set<Overlay>   │ │ to action    │
   │ audioEngine      │ │ audioFullyRevealed│ │ based on    │
   │ visual/audio     │ │ audioCompactPinned│ │ key context │
   │ playlist +       │ │ (Esc chain +     │ │ (visual vs   │
   │ isSuppressed     │ │  exclusivity)    │ │  audio)      │
   └──────────────────┘ └──────────────────┘ └──────────────┘
```

#### AppState

`@MainActor @Observable final class`. Injected into the SwiftUI environment via `.environment(appState)` at the scene level and consumed in views via `@Environment(AppState.self) private var appState`. Holds the SwiftData model context and the three playlist slots that drive the UI. Responsible for:
- Holding the three slots as independent references, kept consistent by explicit load steps (never by deriving one slot from another): the **managed-playlist slot** (`managedPlaylist`, what the whole Manager binds to, any type), the **audio-channel slot** (`audioChannelPlaylist`, persistent), and the visual channel (owned by the coordinator). `lastManagedVideoPlaylist` / `lastManagedImagePlaylist` remember each visual type's last-managed playlist so a scope switch can pre-load it; audio's memory *is* the audio-channel slot.
- Persisting the slot IDs and the Manager scope to the SwiftData `AppStateModel` singleton on change; restoring them on launch (`resolveActivePlaylists` loads the persisted scope's remembered playlist into the managed slot).
- Providing the current app mode (`.welcome`, `.manager`, `.player`).
- **Deriving, not caching, the filtered file lists.** The filter (`filterState`, tag filter *and* service filter) and the current file (`currentFileID`) are persisted, per-playlist `@Model` state; the display-ordered list and the current-file highlight are pure derivations of it (`Playlist.displaySequence` / `playbackSequence`). A view reading `managedPlaylist?.displaySequence` (exposed as `managerFiles`; `audioChannelFiles` / `visualChannelFiles` for the channel slots) re-derives on its own when the model changes — no recompute-and-reconcile machinery, and two slots pointing at the same `Playlist` are consistent for free.
- Driving Manager mode as a **three-scope library** via `managerScope: ManagerScope { case image, video, audio }`. The scope is *only* the sidebar's playlist-type filter — which playlists you can pick to become the managed one — not selection, filter, or routing state. `switchScope(to:)` is the browse gesture: it sets the scope and pre-loads that scope's remembered playlist into the managed slot. One managed selection set (`managerSelection`) belongs to the managed playlist; `scrollSelectionToken` stays as a deliberate "re-center now" event (not a derived value), with `audioScrollToken` its overlay counterpart.
- Converging the select paths onto one `select(_:)` that loads the picked playlist into the managed slot (and, for audio, into the audio channel, stopping whichever audio playlist was live). The overlays keep play-on-select variants: `selectVisualPlaylistInPlayer` and `selectAudioPlaylist`. The audio channel's "current track" is `currentAudioFile`, resolved from the playlist's persisted `currentFileID` against its display list — anchored on the model, not the live engine, so a stopped playlist still shows and resumes from where it left off.
- Applying every filter edit to the target playlist's persisted `filterState` (the `*(on: playlist)` methods: `toggleFilterTag`, `setFilterMode`, `clearTagFilter`, `toggleServiceFilter`, the saved-search API); surfaces re-derive. The one explicit side effect is the live-channel reconcile: when an edit to a playlist that is currently playing removes the file the engine is on, the engine is advanced to a matching file (`reconcileAudioSelection` / the visual analog). A re-scan or trash that removes a file prunes it from `managerSelection`.
- Centralizing scoped folder access for every file mutation (`beginFolderAccess(to:)`), including the stale/denied-bookmark re-grant prompt.
- Exposing optimistic-progress state that the sidebar renders as spinners: folders being scanned into new playlists, playlists with a background re-scan in flight, and playlists being deleted (whose files are removed in batches, yielding between each so the UI stays responsive).

#### PlaybackCoordinator

Owns both mpv instances (video, audio) and the image slideshow timer. Enforces concurrency rules:
- At most one video **or** image playlist playing at a time.
- At most one audio playlist playing in parallel.
- Stopping one playlist does not affect the other channel.

It also owns the single transient **suppression** flag: effective playback is `playing && !suppression`. `[p]`/`[esc]` (pause overlay) and window close activate suppression; Unpause (or `[p]`/`[space]` on the pause overlay) and window reopen lift it. Playlist states are untouched either way.

Keeps each channel's loaded file consistent with its playback sequence. When a filter, re-scan, or deletion reshapes a sequence, `reconcileVisualSelection()` / `reconcileAudioSelection()` jump the engine to the first surviving file if the current one was dropped, or clear the engine when nothing matches. Because loading a file auto-starts it, a `jump` re-suspends the channel afterward unless it should be playing (a paused, suppressed, or overlay-halted channel stays halted). Deleting a playing playlist stops its channel first, so the engine never references models that are about to be freed. Exposes playback state (playing/paused/stopped, current time, duration) as observable properties for UI binding, per channel (`visualCurrentFile`/`audioCurrentFile`, etc.).

#### OverlayManager

Tracks visibility of all overlays in Player mode and enforces exclusivity rules from the feature spec:
- Expanded audio (`.audioExtended`) is exclusive — opening it closes the Visual Overlay.
- Compact audio (`.audioCompact`) closes when a *hotkey-triggered* overlay opens, but may re-appear on top of an open Visual Overlay when summoned by top-edge hover.
- The Visual Overlay suppresses the bottom controls' hover trigger; it closes automatically only when Expanded audio opens.
- Owns **key context** — which target (player vs. Audio Overlay) currently receives arrow/space/loop/seek. The Audio Overlay claims key context only once it is *fully revealed* (slide-in animation complete) and returns it to the player when it closes to Hidden.

`.audioCompact` and `.audioExtended` are two states of one view, `AudioOverlay`: it always draws the compact transport bar and, while `.audioExtended` is active, reveals the expanded lower section. `expandAudioToExtended()` / `collapseAudioToCompact()` toggle between them (collapse pins the compact bar so a stray hover-exit can't dismiss it); `closeAudioOverlay()` returns to Hidden. The overlay mounts only in Player mode.

State is an enum set, not a stack — overlays don't nest arbitrarily.

#### HotkeyRouter

Receives raw key events and routes them to the appropriate handler based on:
1. Is a text input focused? → swallow the event (the field handles it).
2. Is it `[esc]`? → apply the esc priority chain (unfocus input → close overlay → suppress → close window).
3. Does the Audio Overlay hold **key context** (fully revealed)? → route arrow/space/loop/seek to audio controls.
4. Default → player or manager hotkey table. In Manager mode, arrow keys are standard file-list navigation, not audio-overlay control.

Key context is read from the OverlayManager so the router and the overlay layer agree on who owns the keys.

### Playlist state machine

Each playlist tracks its own playback state independently:

```
                    ┌──────────┐
          ┌────────▶│ Stopped  │◀────────┐
          │         └────┬─────┘         │
          │              │ play /        │ stop
          │              │ double-click  │
          │         ┌────▼─────┐         │
          │         │ Playing  │─────────┤
          │         └────┬─────┘         │
          │              │ pause button  │
          │              │               │
          │         ┌────▼─────┐         │
          └─────────│ Paused   │─────────┘
        play button └──────────┘
```

The state is persisted per playlist (`Playlist.playbackState`); the coordinator mirrors it at runtime. The play/pause button in a playlist's own controls (video/image bottom bar, Audio Overlay) toggles Playing ↔ Paused; making another playlist of the same kind active resets the previous one to Stopped.

**Suppression** is a single transient layer on top of these states, owned by the coordinator and never persisted: effective playback is `playing && !suppression`. It is active while the pause overlay is shown or the window is closed; when it lifts (Unpause, window reopen, app relaunch), Playing playlists continue and Paused playlists stay paused.

---

## 5. Service layer

Services encapsulate logic that is independent of UI. They are injected into state objects (not views) and are protocol-based for testability.

### FileSystemService

```
Responsibilities:
  - Resolve security-scoped bookmarks and manage access sessions.
  - Recursively enumerate a folder, classifying files by extension.
  - Determine the dominant media type (or flag as mixed).
  - Capture each file's initial cloud status (local / in cloud / downloading).
  - Detect new/removed files for Update operations.

Key methods:
  scanFolder(bookmark: Data) async throws -> ScanResult
  updatePlaylist(_:) async throws -> UpdateDelta
  trashFiles(_: [URL]) async throws
  renameFile(at: URL, to: String) throws -> URL
```

**File classification** uses a static extension-to-MediaType map:

```swift
static let videoExtensions: Set<String> = ["mp4", "webm", "mov", "avi", "mkv", "m4v"]
static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "jxl", "gif", "heic", "heif", "webp", "tiff", "bmp"]
static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "aiff", "wma"]
```

**Dominance threshold**: a type is *dominant* when files of the other recognized types are only an incidental minority (e.g. a few album-cover images among many audio tracks). The app uses a single concrete boundary: if ≥ 80% of recognized media files are one type, that type is auto-selected; otherwise the folder is **Mixed** and the user is prompted to choose. There is no second threshold — "Mixed" is simply "not dominant."

### TagParser

Pure functions, no state. Easily unit-tested.

```
Responsibilities:
  - Parse tags from a filename string.
  - Detect invalid tagging (more than one bracket pair, nested brackets, or a single group containing any token that isn't a valid tag).
  - Build a new filename after adding/removing/renaming a tag.
  - Validate tag format (letters, digits, underscore, >= 3 chars).

Key functions:
  parseTags(from fileName: String) -> TagParseResult
    // .valid([String]) | .untagged | .invalid
  
  addTag(_ tag: String, to fileName: String) -> String
  removeTag(_ tag: String, from fileName: String) -> String
  renameTag(from: String, to: String, in fileName: String) -> String
```

**Parsing algorithm** (operates on the filename excluding its extension):
1. Scan left to right, tracking bracket nesting depth. Any nesting (a `[` opened while already inside a pair) → `.invalid`.
2. Count balanced top-level `[...]` pairs. More than one → `.invalid`. A single unmatched `[` or `]` that never forms a pair is ignored (treated as literal prose), not invalid.
3. Zero pairs → `.untagged`.
4. Exactly one pair → inspect its space-separated tokens:
   - Empty or whitespace only → `.untagged` (the empty group is removed the next time the file's tags are edited).
   - **Every** token matches `[a-zA-Z0-9_]{3,}` → `.valid(tags)`, lowercased for matching while the on-disk casing is preserved.
   - **Any** token fails (too short, or disallowed character; e.g. `[beach ab]`, `[a b c]`) → `.invalid`. The content is surfaced, never silently dropped.

### PlaybackEngine

Wraps libmpv (for video/audio) and Core Graphics (for images) to provide a clean async interface.

```
Responsibilities:
  - Create and manage mpv instances (one for video, one for audio).
  - Handle end-of-file events to advance to next file.
  - Support seeking, looping, volume control.
  - Provide time observation for progress UI.

Key types:
  MPVClient             — thin Swift wrapper around mpv_handle (C API bridge)
  VideoPlaybackEngine   — owns one MPVClient for video
  AudioPlaybackEngine   — owns one MPVClient for audio
  ImagePlaybackEngine   — owns a Timer-based slideshow driver
```

Each engine exposes its state as stored properties on an `@MainActor @Observable` class (currentTime, duration, isPlaying, isLooping) that the UI observes directly via SwiftUI's observation tracking.

**MPVClient detail**: Each MPVClient instance manages one `mpv_handle`. It exposes a Swift-friendly API:

```swift
class MPVClient {
    private let handle: OpaquePointer        // mpv_handle
    private let queue: DispatchQueue         // serial queue for all mpv API calls
    
    func loadFile(_ url: URL, startPosition: TimeInterval? = nil)
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval)
    func seek(by delta: TimeInterval)
    var volume: Float   // 0–100, mapped to mpv's volume property
    var isLooping: Bool // sets mpv's loop-file property
    
    // Async event stream for UI observation.
    // Uses .unbounded buffer policy — eof-reached and other control events
    // must not be dropped. MainActor consumption is fast enough to prevent backlog.
    var events: AsyncStream<MPVEvent>
}
```

**Command dispatch**: Fire-and-forget commands (`loadFile`, `play`, `pause`, `seek`, `stop`) use `queue.async` to avoid blocking the caller (typically MainActor). Property reads (`volume` getter, `isLooping` getter) use `queue.sync` — these are fast reads of mpv state and return immediately. Property writes (`volume` setter) use `queue.async`. All paths serialize access to `handle` through the same serial queue.

**Event delivery**: `mpv_set_wakeup_callback` signals `queue`. The queue reads events with `mpv_wait_event` and forwards them into an `AsyncStream<MPVEvent>` consumed on MainActor. The stream's `onTermination` handler removes the wakeup callback and releases mpv resources when the consuming task is cancelled or the engine is deallocated.

**Single consumer**: Each `AsyncStream<MPVEvent>` has exactly one consumer — the owning engine (`VideoPlaybackEngine` or `AudioPlaybackEngine`). The engine updates its own observable properties (currentTime, isPlaying, etc.) on MainActor, which the UI and `PlaybackCoordinator` observe through normal SwiftUI observation. AsyncStream does not support multiple consumers; splitting values between two `for await` loops would lose events.

**Looping**: Implemented via mpv's `loop-file=inf` property. When loop is toggled on, the property is set. When toggled off or the user manually navigates, it is reset to `no` and normal advancement resumes.

### ThumbnailService

`@MainActor @Observable`, injected into the environment.

```
Responsibilities:
  - Generate thumbnails for image files (CGImageSource with kCGImageSourceThumbnailMaxPixelSize).
  - Generate thumbnails for video files (AVAssetImageGenerator, falling back to a libmpv
    frame extraction for containers AVFoundation can't open — see MPVThumbnailer).
  - Cache decoded images in memory (NSCache) over an on-disk PNG cache (Caches directory).
  - Provide async, cancellable thumbnail loading for the gallery, generated and decoded
    off the main actor.

Key methods:
  thumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) async -> (image: NSImage?, duration: TimeInterval?)
  cachedThumbnail(for file: PlaylistFile, in playlist: Playlist, maxPixelSize: Int) -> NSImage?
```

Thumbnails are generated lazily on first request and cached. The on-disk cache key is the SHA-256 of `relativePath + modification date + max pixel size`, so an edited file (or a different requested size) yields a fresh thumbnail. Generation and PNG decode run off the main actor: the `@MainActor` entry point reads the model, then `@concurrent` workers resolve the bookmark, render, and return a ready-to-draw `NSImage` (decoding off-main, so scrolling never blocks on a draw-time decode — see §10). `cachedThumbnail` is a synchronous in-memory lookup so a cell shown before paints without disk I/O or a placeholder flash. Each gallery cell loads via `.task(id:)`, which cancels the work when the cell scrolls off-screen.

Video frames come from `AVAssetImageGenerator`; when it can't open the container (notably `.webm` and `.mkv`, which AVFoundation won't demux), generation falls back to **`MPVThumbnailer`** — a stateless helper that decodes one frame with libmpv, the same engine that plays those files. Each call spins a short-lived, windowless mpv instance with the `image` video output (`vo=image`), seeks 10% in, writes a single PNG to a private temp directory, and tears the handle down; the PNG is then downscaled through the same `imageThumbnail` path as still images. It owns a fresh handle per extraction and never touches the playback engines' `MPVClient` or its render context, so it is independent of the player's lifecycle. Extractions are serialized on a single background-QoS queue, since each is a full software decode and misses are rare once the disk cache is warm; a per-call deadline bounds a pathological decode.

Generation also carries the video's **running time** back with the frame, since the decode already determines it: `AVAssetImageGenerator`'s path reads it from `AVURLAsset.load(.duration)` in parallel with the frame, and `MPVThumbnailer.frame` reads the loaded instance's `duration` property before tearing the handle down. `thumbnail` threads it up beside the image, so the gallery cell sets `PlaylistFile.duration` in the same continuation that delivers the thumbnail — the length badge appears *with* the thumbnail, never as a second pass. A thumbnail served from cache (disk or memory) reports no duration; the cell then relies on the persisted value, or `DurationService` for the rare case it is missing.

### AudioStripper

The **Remove Audio** file action removes a video's audio track through **`AudioStripper`**, which remuxes with **libavformat** — the FFmpeg libraries libmpv already links and the bundle step already embeds (exposed to Swift as the `Cffmpeg` Clang module). It opens the input, allocates an output context whose muxer is inferred from the output extension, copies the video stream's `AVCodecParameters` into a new stream, and runs an `av_read_frame` → `av_interleaved_write_frame` loop that forwards only the video packets (rescaling timestamps to the output stream's time base) and drops everything else. No decode or re-encode, so it is fast and lossless; it works for every container the player can open — the route AVFoundation can't take for webm/mkv — and needs no external `ffmpeg` binary. (libmpv's own encode mode is not used: this build's mpv dropped stream-copy, so it can only re-encode.) The blocking copy runs on a background-QoS queue.

The orchestration lives on `AppState` (`stripAudio(from:)`), mirroring the delete confirmation flow: a `pendingAudioStrip` set (raised by the row or overlay command, pruned when a re-scan removes a referenced file, and registered in `HotkeyRouter.hasBlockingConfirmation` so the alert owns `[enter]`/`[esc]`) gates a background `Task`. Under one scoped-access session it remuxes each file to a hidden sibling in the same folder (dotfiles are skipped by scans, and a same-volume rename into place can't fail for space once the bytes are written), moves the original to the Trash as a recoverable backup, and swaps the result in. A video currently on the visual channel is reloaded via `coordinator.jump` + `seek` to resume at its captured position, since the player still holds the trashed original open. `strippingFileIDs` drives a per-row spinner while the work runs.

### DurationService

`@MainActor @Observable`, injected into the environment.

```
Responsibilities:
  - Extract the running time of a video or audio file (AVURLAsset.load(.duration),
    falling back to a libmpv duration probe for containers AVFoundation can't open
    — see MPVThumbnailer).
  - Cache the result on the model (PlaylistFile.duration) for instant later reads.

Key method:
  duration(for file: PlaylistFile, in playlist: Playlist) async -> TimeInterval?
```

The service is media-type-agnostic — it reads a container's running time without consulting the playlist's media type — so audio-scope file rows get lengths the same way video does.

This is the **standalone** path, used where no thumbnail is generated to carry the length along: the file-list rows (which have no thumbnails) and the gallery's cache-hit case (a thumbnail served from cache reports no duration). The `@MainActor` entry point returns `PlaylistFile.duration` when already known, otherwise a `nonisolated` worker resolves the bookmark, reads the duration, and writes it back onto the model; rows and cells load via `.task(id:)` for video and audio playlists (images have no timeline), and the persisted value means the indicator appears instantly on later displays and across launches. For AVFoundation-readable containers the length comes from `AVURLAsset.load(.duration)` — a moov-atom read, no frame decode. The webm/mkv fallback is **`MPVThumbnailer.duration(at:)`**, which loads the file into a windowless, paused mpv instance (`vo=null`) just far enough to read the demuxer's `duration` property — decoding nothing — on the same pool as frame extraction.

In the **gallery**, a freshly generated thumbnail already delivers the length (see ThumbnailService), so the cell sets `PlaylistFile.duration` straight from the thumbnail result and only consults `DurationService` when the model still lacks a value (a cache-served thumbnail). A webm/mkv gallery cell therefore pays a single libmpv decode for both its thumbnail and its length, with no separate probe queued behind the frame extractions.

### BookmarkService

```
Responsibilities:
  - Create security-scoped bookmarks from user-selected folder URLs.
  - Resolve bookmarks back to URLs with security-scoped access.
  - Track active access sessions (startAccessingSecurityScopedResource / stop).
  - Surface stale/denied bookmarks by throwing, so the caller can re-prompt. The re-grant
    flow lives in AppState.beginFolderAccess(to:): it prompts with an NSOpenPanel, recreates
    and persists the bookmark from the freshly granted URL, then retries the operation.

Lifecycle:
  - startAccessingSecurityScopedResource() is called when a playlist becomes active
    (selected in Manager, or started in Player).
  - stopAccessingSecurityScopedResource() is called when a playlist transitions to
    Stopped state and is no longer the selected playlist.
  - A reference count tracks concurrent users of the same bookmark (e.g., an audio
    playlist and a video playlist backed by the same folder). Access is released only
    when the count drops to zero.
```

### CloudFileService

```
Responsibilities:
  - Determine each file's cloud status: local, in the cloud (placeholder/evicted), or downloading.
  - Observe status changes live via NSMetadataQuery (scoped to active playlist folders) and
    URL resource values (.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey).
  - Request on-demand downloads (FileManager.startDownloadingUbiquitousItem(at:)).
  - Prefetch ahead: while the current file plays, request downloads for the next N files in
    playback order so they are local by the time playback reaches them.
  - Publish per-file status so list/gallery rows can show "in the cloud" / "downloading" badges.

Key methods:
  status(for url: URL) -> CloudStatus
  requestDownload(_ url: URL)
  prefetch(after index: Int, in playlist: Playlist, count: Int)
  statusStream(for playlist: Playlist) -> AsyncStream<[PlaylistFile.ID: CloudStatus]>
```

Status observation runs off the main actor; published status snapshots are `Sendable` value types
(`[PlaylistFile.ID: CloudStatus]`) delivered to `@MainActor` consumers via `AsyncStream`, mirroring the
MPVClient event pattern.

---

## 6. UI architecture

### Window model

Single `WindowGroup` in the SwiftUI `App` scene. The window's content switches between three top-level views. A `Settings` scene provides the preferences window (Cmd+,).

Because the app is single-window, the default "New Window" command is removed so users cannot open duplicate instances.

```swift
@main
struct ShuTaPlaApp: App {
    @State private var appState = AppState()
    @State private var thumbnailService = ThumbnailService()

    var body: some Scene {
        WindowGroup {
            switch appState.mode {
            case .welcome:    WelcomeView()
            case .manager:    ManagerView()
            case .player:     PlayerView()
            }
            .environment(appState)
            .environment(thumbnailService)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
```

**Fullscreen transitions**: When entering Player mode (for video/image), the app calls `NSWindow.toggleFullScreen(_:)` on the hosting window via `NSViewRepresentable` bridge. The view switch and fullscreen toggle happen together. Exiting Player mode (Stop) reverses both.

**Window close vs. app quit**: Closing the window (via `[esc]` or the close button) hides the window but keeps the app running. The Dock icon and menu bar remain. Clicking the Dock icon or using the app menu reopens the window in its prior state.

### Manager mode layout

```
┌──────────────────────────────────────────────────────────────────┐
│[][Image][Video][Audio] +│ Playlist name  ▶︎ ...│             🏷 []│  ← toolbar
├─────────────────────────┬─────────────────────┬──────────────────┤
│  ┌────────────┐         │                     │  ┌────────────┐  │
│  │ audio inlet│         │                     │  │  Filter    │  │
│  ├────────────┤         │  Filter controls    │  │  controls  │  │
│  │            │         │                     │  ├────────────┤  │
│  │ Playlists  │         │  File list /        │  │  Tag       │  │
│  │ (scope)    │         │  gallery            │  │  panel     │  │
│  │            │         │                     │  │            │  │
│  │ (collaps-) │         │                     │  │ (collaps-) │  │
│  └────────────┘         │                     │  └────────────┘  │
└─────────────────────────┴─────────────────────┴──────────────────┘
```

The Manager shell is an AppKit `NSSplitViewController` (`ManagerSplitScene` / `ManagerSplitViewController`) that hosts the three SwiftUI panes (`PlaylistSidebar`, `PlaylistCenterView`, `TagSidebar`) in `NSHostingController`s, bridged into the SwiftUI `WindowGroup` via `NSViewControllerRepresentable` (`ManagerView` → `ManagerSplitScene`). Its custom `NSToolbar` has three regions — sidebar / center / inspector — bounded by `NSTrackingSeparatorToolbarItem`s pinned to the split dividers, so each region's items align over its pane. `ManagerChrome` (an `@Observable`: `sidebarCollapsed`, `inspectorVisible`, `managingTags`) is the shared source of truth the controller and the SwiftUI panes both read. The representable's `sizeThatFits` returns the full proposed size so a divider drag hands freed width to the center pane and a collapsing pane stays pinned to the window edge.

**Toolbar regions**: leading — the **scope tabs** (`ScopeTabButton`, one per scope — Image · Video · Audio — a custom toggle so a click on the already-active scope can collapse the sidebar; a native segmented `Picker` can't report that re-click) and the **New Playlist `+`**; center — the managed playlist's name via `.navigationTitle` and its type's actions (image/video: Play · Reshuffle · List/Gallery · Settings; audio: Reshuffle · Settings); trailing — the tag controls (Manage Tags toggle, inspector show/hide). Full-height-sidebar toolbar coordination (reserving a sidebar toolbar region and relocating its items on collapse) engages only when the split controller is the window's `contentViewController`; here SwiftUI owns the window content, so the `+` overflows rather than relocating when the sidebar collapses — an accepted limitation.

**Sidebar structure**: `PlaylistSidebar` pins the **audio inlet** (`AudioInlet`) at the top via `.safeAreaInset(edge: .top)` in every scope, then lists the active scope's single section — Image, Video, or Audio — with full management (inline rename, delete with confirmation, drag reorder); a row's selection makes that playlist the managed one (`appState.select`), and the selected row is the managed playlist. Create is the toolbar's New Playlist. The playlist delete confirmation is presented here for every scope. Rows come from a `@Query` in the view (not inside `@Observable` classes, where `@Query` would conflict with the `@Observable` macro), filtered by `mediaType`, sorted by `sortOrder`.

**Player-mode playlist switching**: Quick switching lives in the overlays' selectors, not a separate panel — the `LibrarySurface` selector column lists the active channel's single media type and is a pure switcher (no create/rename/delete/reorder). Selecting a playlist immediately starts playing it. Full management stays in Manager's sidebar.

### Player mode layout

```
┌──────────────────────────────────────────────────────────┐
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ top hover zone ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓    │
│ ▓                                                      ▓ │
│ ▓     ┌─────────────────────────────────────┐          ▓ │
│ l     │                                     │          ▓ │
│ e     │         Media content               │          ▓ │
│ f     │      (video / image)                │          ▓ │
│ t     │                                     │          ▓ │
│       │                                     │          ▓ │
│ h     └─────────────────────────────────────┘          ▓ │
│ o                                                      ▓ │
│ v     ┌─────────────────────────────────────────────┐  ▓ │
│ e     │  Visual Overlay (when visible)              │  ▓ │
│ r     │  slides up from bottom                      │  ▓ │
│       └─────────────────────────────────────────────┘  ▓ │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ bottom hover zone ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓    │
└──────────────────────────────────────────────────────────┘
```

**Hover zones** are implemented using `NSTrackingArea` (via an NSView bridge) rather than SwiftUI `.onHover`, which doesn't reliably detect edge-of-screen hover in fullscreen. Each zone has a thin invisible tracking area along the window edge.

**Overlay rendering**: Overlays are SwiftUI views composed via `.overlay()` and `.transition()` modifiers on the PlayerView, controlled by the OverlayManager's observable state. Overlay show/hide uses `withAnimation` (event-driven) rather than the deprecated `.animation()` without a value parameter. Transitions use `.move(edge:)` or `.opacity` paired with the `withAnimation` block in the OverlayManager's `show()`/`hide()` methods.

### Overlay exclusivity implementation

The OverlayManager maintains a set of active overlays and enforces rules declaratively:

```swift
enum Overlay: Hashable {
    case filesTags
    case audioCompact
    case audioExtended
    case pauseOverlay
    case bottomControls
}

@MainActor @Observable
final class OverlayManager {
    private(set) var active: Set<Overlay> = []
    
    func show(_ overlay: Overlay) {
        // Apply exclusivity rules before adding
        switch overlay {
        case .audioExtended:                 // exclusive — closes everything else
            active.remove(.filesTags)
            active.remove(.audioCompact)
            active.remove(.bottomControls)
        case .filesTags:                     // hotkey overlay — closes compact audio + hover overlays
            active.remove(.audioCompact)
            active.remove(.bottomControls)
        case .audioCompact:
            // Compact audio may sit on top of an open Visual Overlay (top-edge hover),
            // so it does NOT close it. It only yields to Extended audio (handled above).
            break
        case .bottomControls:
            // Passive hover chrome is suppressed while Visual Overlay or Extended audio is open.
            if active.contains(.filesTags) || active.contains(.audioExtended) { return }
        case .pauseOverlay:                  // suppression UI — opaque, covers the whole screen
            active.removeAll()
        }
        active.insert(overlay)
    }
}
```

---

## 7. File system and tags

### Folder scanning pipeline

```
User picks folder
       │
       ▼
  Create security-scoped bookmark
       │
       ▼
  Recursive enumeration (FileManager.enumerator)
       │
       ▼
  Classify each file by extension → video/image/audio/unknown
       │
       ▼
  Count by type. If >= 80% one type → auto-assign.
  If mixed → prompt user to choose.
       │
       ▼
  Filter to chosen media type only
  (other files are retained as skipped entries — isSkipped — for the skipped-files filter)
       │
       ▼
  Parse tags from each filename (TagParser)
       │
       ▼
  Shuffle file list (Fisher-Yates)
       │
       ▼
  Persist Playlist + PlaylistFile entries to SwiftData
       │
       ▼
  Build tag frequency cache
```

### Update vs. Reshuffle

| Operation | Reads disk | New files | Removed files | Order | Position |
|-----------|-----------|-----------|---------------|-------|----------|
| **Update** | Yes | Appended at end | Pruned | Preserved | Preserved |
| **Reshuffle** | Yes | Included | Removed | New random shuffle | Reset to 0 |

**Auto-update**: When a playlist becomes the active playlist (selected in Manager or started in Player), an update runs as a background Task. The UI is not blocked; new files appear in the list as the update completes.

Update prunes files that have disappeared from disk. Every re-read (the Reshuffle button and the automatic Update) runs as a background Task with a small "sync in progress" indicator shown while it is running — the UI is never blocked.

### Tag editing flow

```
User edits tag in UI
       │
       ▼
  TagParser builds new filename
       │
       ▼
  FileSystemService.renameFile(at:to:)
       │
       ▼
  On success:
    - Update PlaylistFile.fileName, .relativePath, .tags in SwiftData
    - Update Playlist.tagFrequency cache
    - PlaybackCoordinator reloads the file in mpv if it is currently playing
       │
       ▼
  On failure (name collision, permission error, read-only or disconnected/offline
              volume, or a move-to-Trash failure):
    - Leave the file and its playlist entry untouched (never dropped)
    - Surface a clear, non-blocking notification so the user can resolve it
    - No model changes
    This graceful-failure rule applies to ALL file mutations: tag edits, renames,
    deletes, and playlist-wide tag operations.
```

Renaming is synchronous and atomic (POSIX rename). The file stays in the same directory; only the name component changes.

**Shared tag control**: `TagTokenField` is the one multiselect-with-autocomplete control behind both the tag editor and the filter. Selected tags render as removable chips inside a bordered field; typing filters a floating dropdown — ranked by match against the typed string (exact, then prefix, then substring) and then by `tagFrequency` — that overlays the controls below it rather than pushing them down (so each call site raises the control's `zIndex` above its following siblings). Arrow-up/down move the dropdown highlight and `[enter]` adds the highlighted row; with the input empty, arrow-left/right step the caret one chip at a time, a quick double-left/right jumps to the first/last chip, and `[delete]` removes the chip at the caret. The static `options(query:knownTags:selected:allowsCreate:)` computes the ranking and is unit-tested directly. `TagEditorView` instantiates it with `allowsCreate: true` (a valid, unused typed string trails the dropdown as a "create" row and adds the tag to the selected file(s) on commit); `FilterBar` with `allowsCreate: false` (search-to-select only, adding to `filterState`). Playlist-wide tag rename / remove live in `TagSidebar`: a `ManagerView` toolbar button (beside the inspector show/hide control) drives a `managingTags` binding that swaps the panel for a `PlaylistTagsView` listing every tag in `playlist.tagFrequency`, with inline rename (the field auto-focuses) and a confirmed remove-from-all-files, both routed through `AppState.renameTagAcrossPlaylist` / `removeTagAcrossPlaylist`. A rename onto an existing tag is refused with a message; `TagParser` substitutes a placeholder base when an edit would otherwise leave a file with an empty name.

The text input is a borderless `NSTextField` wrapper (`TokenTextField`), not a SwiftUI `TextField`, so focus and the caret-edge key commands come straight from AppKit — the layer SwiftUI's `@FocusState`/`onKeyPress` miss on an empty field. The field is only inserted once the control is clicked (it never auto-focuses on appear), reports begin/end editing through the delegate, and routes `delete`/arrows/`return`/`esc` via `doCommandBy:` only at the matching caret edge. While focused it runs a local `leftMouseDown` monitor: a click outside the control and its open dropdown resigns focus *without* consuming the event, so a single click elsewhere (another control, a playlist row, empty chrome) both closes the field and lands. The monitor maps the click into the control's coordinate space from the input's own AppKit-window and SwiftUI-global frames.

**Invalid-tagging files**: `TagEditorView` checks the active file's `taggingStatus`. When it is `.invalid`, the chip editor is disabled and replaced with an "invalid tag syntax" message plus a plain filename-rename field; tag add/remove/rename are not offered (they would rewrite the name and could drop the malformed bracket content). The editor re-enables automatically once a rename makes the filename parse as `.valid` or `.untagged`. In a Manager multi-selection, `.invalid` files are excluded from batch tag operations and surfaced for individual fixing.

### Playlist-wide tag operations

**Rename tag across playlist**: Iterate all PlaylistFiles that contain the tag, compute new filenames, rename each on disk, update models. Disk renames are attempted one at a time; if a rename fails, that file is skipped and added to an error list. SwiftData model updates are applied only for successfully renamed files. The error list is surfaced to the user after the batch completes.

**Remove tag across playlist**: Same as rename, but the tag is dropped instead of replaced.

---

## 8. Media playback

### Video playback

```
VideoPlaybackEngine
  │
  ├── mpv: MPVClient
  ├── renderView: MPVVideoView       (NSView subclass, hosted via NSViewRepresentable)
  │
  ├── loadFile(_ url: URL, startPosition: TimeInterval?)
  │     → mpv.loadFile(), seeks if position provided
  │
  ├── advanceToNext() / returnToPrevious()
  │     → Queries PlaybackCoordinator for next/prev file
  │     → Loads new file, optionally saves position of current file
  │
  ├── seek(by delta: TimeInterval)
  │     → Relative seek for ±3s hotkey
  │
  └── Event observation
        → Consumes mpv.events AsyncStream
        → time-pos updates → progress bar
        → eof-reached → advance to next file
```

**End-of-file handling**: When mpv fires an `eof-reached` event:
- If looping is on → mpv's `loop-file` property handles replay internally.
- If looping is off → `advanceToNext()` is called.
- Advancing walks the file list by `sortOrder`, starting after the current file and wrapping past the last file to the first (previous from the first file wraps to the last). The order is never reshuffled by playback. With a filter active, non-matching files are skipped, so wrap-around applies to the filtered sequence.
- The current file is tracked by `currentFileID`, so toggling filters or an Update prune/append never loses the position.
- On each advance the coordinator triggers cloud prefetch for the upcoming files (see PlaybackCoordinator orchestration → Cloud prefetch).

**HDR**: mpv handles HDR natively. The `MPVOpenGLLayer` enables EDR pass-through with a floating-point backbuffer, `wantsExtendedDynamicRangeContent = true`, and an extended-sRGB colorspace, paired with mpv's `--target-colorspace-hint=yes`, so HDR clips reach EDR-capable displays. Mastering-display luminance metadata needs a Metal layer (unreachable through the libmpv render API) — accepted.

**MPVVideoView**: A custom `NSView` subclass backed by an `MPVOpenGLLayer` (a `CAOpenGLLayer`). mpv draws into the layer through the libmpv OpenGL render API: the layer creates the `mpv_render_context` once its CGL context exists, redraws on the render-update callback, and renders each frame into the framebuffer CoreAnimation bound. Wrapped in `NSViewRepresentable` for SwiftUI embedding.

### Image playback

```
ImagePlaybackEngine
  │
  ├── currentImage: NSImage?      (published for UI binding)
  ├── fitMode: ImageFitMode       (published)
  ├── transform: ImageTransform   (pan offset + zoom scale)
  │
  ├── loadFile(_ url: URL)
  │     → Load via CGImageSource for efficient decoding
  │     → Reset transform to identity
  │     → Publish new image
  │
  ├── slideshowTimer: Timer?
  │     → When slideshow is on, fires after interval to advance
  │
  └── cycleFitMode()
        → fit → cover → original → fit
```

**Pan and zoom**: Implemented via SwiftUI gestures on the image view:
- `MagnifyGesture` for pinch-to-zoom (trackpad).
- `NSEvent.scrollWheel` (via NSViewRepresentable bridge) for scroll-wheel zoom.
- `DragGesture` for panning.
- Transform state (offset + scale) is stored on the engine and reset on file change or fit-mode cycle.

**HDR images**: Loaded via `CGImageSource` with `kCGImageSourceShouldAllowFloat` option. Displayed in an EDR-capable layer.

### Audio playback

```
AudioPlaybackEngine
  │
  ├── mpv: MPVClient             (independent instance from video)
  │
  ├── loadFile(_ url: URL, startPosition: TimeInterval?)
  ├── advanceToNext() / returnToPrevious()
  ├── seek(by delta: TimeInterval)
  │
  └── Volume is set via mpv's volume property (0–100), independent of system and video volume
```

The audio mpv instance is configured with `--vo=null` (no video output) since it only plays audio tracks.

**Parallel mixing**: On macOS, two mpv instances output to CoreAudio simultaneously. Each instance's `volume` property controls its contribution to the mix independently. No additional audio session configuration is needed.

### PlaybackCoordinator orchestration

The coordinator is the central authority for playback decisions:

```swift
@MainActor @Observable
final class PlaybackCoordinator {
    let videoEngine: VideoPlaybackEngine    // owns MPVClient for video
    let imageEngine: ImagePlaybackEngine    // timer-based, no mpv
    let audioEngine: AudioPlaybackEngine    // owns MPVClient for audio
    
    // Enforces: at most one video XOR image playing
    func play(playlist: Playlist) {
        switch playlist.mediaType {
        case .video:
            imageEngine.stop()           // stop any image playlist
            videoEngine.start(playlist)
        case .image:
            videoEngine.stop()           // stop any video playlist
            imageEngine.start(playlist)
        case .audio:
            audioEngine.start(playlist)  // independent channel
        }
    }
    
    // Suppression ([p], pause overlay, window close) — transient, never persisted.
    // Effective playback = playing && !isSuppressed; playlist states are unchanged.
    private(set) var isSuppressed = false
    func suppress() { ... }
    func unsuppress() { ... }
}
```

**Cloud prefetch**: On each file change (and when a playlist starts), the coordinator asks the `CloudFileService` to prefetch the next files in playback order, so they are local before playback reaches them. If the file playback is about to reach is still in the cloud, the coordinator requests its download immediately and the row shows the downloading indicator; if it cannot be made local in time, the same "advance to the next available file" rule used for missing files applies.

---

## 9. Hotkey system

### Architecture

Key events are captured app-wide via `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`. This approach:
- Works in fullscreen (unlike SwiftUI `.onKeyPress` which can lose focus).
- Intercepts events before they reach SwiftUI's responder chain.
- Allows the HotkeyRouter to decide routing before any view sees the event.
- Returning `nil` from the monitor consumes the event — this also keeps `[esc]` (and arrows) from triggering the system's default exit-from-fullscreen behavior, so the esc priority chain stays in control.

**Consumption semantics.** The monitor closure is `{ [weak self] event in guard let self else { return event }; return self.handle(event) }`. `handle` returns `nil` to consume or the event to pass through; there is deliberately **no `?? event` fallback**, which would resurrect every consumed event and ring the system beep on every handled key. `handle` also:
- Passes through any **Command/Control** combination untouched, so menu shortcuts (Cmd+Q, Cmd+,) and the like are never hijacked by the bare-key router.
- Passes through everything while a **text field** is first responder, so focused inputs type normally.
- In **Player mode**, swallows any leftover bare key that no rule handled — the immersive fullscreen player has nowhere for a stray key to go, so this keeps it from beeping.

### Routing priority

```
Key event arrives
       │
       ▼
  1. Is it a Command/Control combo, or is a text field first responder?
     YES → return the event (pass through to the menu system / focused field).
     NO  → continue.
       │
       ▼
  1b. Is a trash confirmation open (Player [delete], or the Manager confirmation)?
     → [enter] confirms (Player: trash + advance), [esc] cancels, all other keys
       swallowed — the dialog holds key context until it closes, so nothing beeps.
       │
       ▼
  2. Is it [esc]? → Apply esc priority chain:
     a. Tag input focused → unfocus
     b. Overlay open → close topmost
     c. Playing → activate suppression, show the pause overlay
     d. Suppressed (pause overlay shown) → close window; suppression stays active while closed
     e. Manager → cancel an in-progress operation (rename, dialog, tagging) if any, otherwise close window
       │
       ▼
  3. Is it [space]?
     → If the pause overlay is shown: end suppression (same as pressing Unpause).
     → If playing: advance to next file in active playlist.
     → If the Audio Overlay holds key context: applies to the audio playlist instead of video/image.
       │
       ▼
  4. Does the Audio Overlay hold key context (revealed AND fully animated in)?
     YES → route arrow keys, [space], [l], and seek to audio controls.
     NO  → continue.
       │
       ▼
  5. Is app in Player mode?
     YES → player hotkey table ([tab] toggles Visual Overlay; [arrow up] opens it
           but never closes it; [arrow down] closes it or reveals Compact audio;
           [s] stops to Manager; [delete] raises the trash confirmation).
     NO  → manager hotkey table (arrows move the file selection — 1-D in the list,
           2-D in the gallery, stepping a full row on up/down and one cell on
           left/right; [enter] plays the selected file). There is no Audio Overlay
           in Manager mode — the audio channel is driven by the sidebar inlet — so
           arrows always stay with file-list navigation.
```

### Modifier key handling

`[right option] + arrow` for seeking requires detecting the right Option key specifically. This is done by checking `event.modifierFlags` for `.option` and `event.keyCode` for the right-side Option key code (61).

`[shift]` for fit mode cycling checks `event.modifierFlags.contains(.shift)`.

---

## 10. Concurrency model

### Project settings

Swift 6 language mode with **default actor isolation set to `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and Approachable Concurrency — the Xcode 26 defaults for new projects). Everything is MainActor-isolated unless declared otherwise; the explicit `@MainActor` annotations shown in this document are then redundant but kept for clarity. Off-main work is opted into explicitly: `actor` types (`FileSystemService`), the MPVClient serial queue, and `@concurrent` functions. **Under Approachable Concurrency a plain `nonisolated async` function runs on the caller's actor**, so a CPU-bound helper awaited from the main actor stays on the main thread unless marked `@concurrent` (as the thumbnail generation/decode workers are). `nonisolated` alone is not enough to leave the main actor here.

### Actor boundaries

```swift
actor FileSystemService {
    // All disk I/O is serialized through this actor
    func scanFolder(...) async throws -> ScanResult
    func renameFile(...) async throws -> URL
    func trashFiles(...) async throws
}
```

File system operations are inherently sequential for safety (avoid renaming a file while scanning). The actor serializes access without explicit locks.

### Main actor usage

All `@Observable` state objects and SwiftUI views run on `@MainActor`. When a service completes work on a background actor, results are delivered to the main actor:

```swift
// In a view model or state object (@MainActor)
func reshuffle(playlist: Playlist) async {
    let result = await fileSystemService.scanFolder(bookmark: playlist.folderBookmark)
    // Back on MainActor — safe to update SwiftData and UI state
    playlist.files = result.files
}
```

### Background tasks

| Operation | Approach |
|-----------|----------|
| Folder scan (create/reshuffle) | Structured Task, shows progress indicator |
| Auto-update on playlist activation | Structured `Task` from `@MainActor` context; the `await fileSystemService.scanFolder(...)` call hops off MainActor naturally via actor isolation. Non-blocking — results merged on return. |
| Thumbnail generation | Per-cell `.task(id:)`; generated and decoded on `@concurrent` workers off the main actor, cancellable on scroll |
| File rename (tag edit) | Inline await on FileSystemService, fast enough to feel synchronous |
| Batch tag rename/remove | Structured Task with progress, cancellable |

---

## 11. Persistence and lifecycle

### What is persisted and where

| Data | Storage | When written |
|------|---------|-------------|
| Playlists, files, preferences | SwiftData | On every mutation (SwiftData auto-save) |
| Active playlist IDs | SwiftData (AppStateModel) | On playlist activation/deactivation |
| Playback state (per playlist) | SwiftData (Playlist) | On every Stopped/Playing/Paused transition. Suppression is runtime-only and never stored. |
| Last-played file (`currentFileID`) | SwiftData (Playlist) | On file advance |
| File position within file | SwiftData (PlaylistFile) | Only when `playlist.preferences.filePositionPersistence` is enabled. Written periodically (every 5s) during playback and on file change/stop. |
| Window frame | SwiftData (AppStateModel) | On window move/resize (debounced) |
| Security-scoped bookmarks | SwiftData (Playlist) | On playlist creation |
| Thumbnail cache | File system (Caches dir) | On generation |

### App lifecycle events

- **Launch**: Load persisted state and reconstruct the PlaybackCoordinator. Playlists in Playing state resume, Paused ones stay paused — relaunching behaves the same as reopening the window. Restore window frame.
- **Window close** (not quit): Persist current state and activate suppression. Playlist states are unchanged.
- **Window reopen**: Lift suppression — Playing playlists continue, Paused ones stay paused.
- **App termination**: Final persist of all playback positions and state.
- **Folder becomes inaccessible** (bookmark stale): On a file mutation, prompt the user to relocate the folder and refresh the bookmark, then retry (`AppState.beginFolderAccess(to:)`). Persistent inaccessibility surfaces an error in the playlist header with an option to re-select the folder.

---

## 12. Error handling strategy

| Scenario | Behavior |
|----------|----------|
| File missing during playback | Skip silently, remove from playlist, advance to next. |
| File missing during scan/update | Prune from playlist (Update mode) or don't include (Reshuffle). |
| Corrupt/unplayable media file | Skip, advance to next. Increment skipped-files count. |
| Folder access lost (stale bookmark) | On a file mutation, prompt to relocate the folder and refresh the bookmark, then retry. Persistent inaccessibility shows an inline error on the playlist. |
| File rename fails (permissions, collision, read-only/offline volume) | Leave file untouched. Show a non-blocking notification. No model changes. |
| File move-to-Trash fails | Leave file untouched. Show a non-blocking notification. No model changes. |
| Disk full during rename | Leave file untouched. Show a non-blocking notification. No model changes. |
| All files filtered out | Show "no files match filter" empty state. Playback stops if playing. |
| File still in the cloud when playback reaches it | Request download on demand, show downloading indicator. If not local in time, advance to next available file. |
| Cloud download fails / times out | Mark the file's status, advance to next available file (same as missing). |
| Playlist folder deleted | Mark playlist as unavailable. Show in sidebar with warning icon. |

---

## 13. Accessibility

While ShuTaPla is primarily hotkey-driven in Player mode, all interactive UI must support VoiceOver and standard macOS accessibility patterns.

### Manager mode

- All buttons use `Button` (not `onTapGesture`) for built-in VoiceOver support.
- File list rows provide `accessibilityLabel` with the filename and tag summary.
- Tag chips in the editor are grouped with `accessibilityElement(children: .combine)` so VoiceOver reads them as a set.
- Collapsible panels announce their state (`accessibilityValue` of "collapsed" / "expanded").
- Filter controls (tag multi-select, AND/OR switch) have explicit `accessibilityLabel` values.

### Player mode

- Pause overlay buttons ("Unpause", "Stop") are standard `Button` elements.
- Playback controls bar uses `accessibilityLabel` for icon-only buttons (previous, next, loop, volume).
- Volume sliders use `accessibilityValue` with percentage.
- Visual Overlay file list follows the same patterns as Manager mode.

### General

- Use `@ScaledMetric` for custom spacing/sizing that should respect Dynamic Type.
- Semantic fonts (`.body`, `.headline`) are used throughout — no hardcoded font sizes.
- Semantic colors (`.primary`, `.secondary`, `.background`) are used for automatic light/dark mode support.

---

## 14. Directory structure

The repo root contains the Xcode file-system-synchronized groups `ShuTaPla/` (app source), `ShuTaPlaTests/`, `ShuTaPlaUITests/`, and `doc/` — files created on disk inside them appear in Xcode automatically.

```
ShuTaPla/                            (app source)
├── App/
│   ├── ShuTaPlaApp.swift            // @main, scene definition, container setup
│   └── AppConstants.swift           // extension maps, thresholds, magic numbers
│
├── Models/
│   ├── Playlist.swift               // @Model
│   ├── PlaylistFile.swift           // @Model
│   ├── AppStateModel.swift          // @Model (persisted singleton)
│   ├── GlobalSettings.swift         // @Model (persisted singleton)
│   ├── PlaylistPreferences.swift    // Codable struct
│   ├── FilterState.swift            // Codable struct
│   ├── SavedSearch.swift            // Codable struct
│   └── Enums.swift                  // MediaType, ImageFitMode, ViewMode, etc.
│
├── State/
│   ├── AppState.swift               // @Observable, top-level runtime state
│   ├── PlaybackCoordinator.swift    // @Observable, orchestrates engines
│   ├── OverlayManager.swift         // @Observable, overlay visibility + rules
│   └── HotkeyRouter.swift           // NSEvent monitor, routing logic
│
├── Services/
│   ├── FileSystemService.swift      // actor, folder scanning, rename, trash
│   ├── TagParser.swift              // pure functions, no state
│   ├── BookmarkService.swift        // security-scoped bookmark management
│   ├── CloudFileService.swift       // iCloud status detection, on-demand download, prefetch
│   ├── ThumbnailService.swift       // async thumbnail generation + caching
│   └── MPVThumbnailer.swift         // libmpv video-frame fallback for webm/mkv thumbnails
│
├── MPV/
│   ├── MPVClient.swift              // Swift wrapper around mpv_handle + OpenGL render context
│   ├── MPVVideoView.swift           // NSView + CAOpenGLLayer; mpv renders via the render API
│   ├── MPVEvent.swift               // Swift enum mapping mpv events
│   └── Cmpv/                        // Clang module exposing libmpv (module.modulemap + shim.h)
│
├── Engines/
│   ├── VideoPlaybackEngine.swift    // owns MPVClient for video
│   ├── AudioPlaybackEngine.swift    // owns MPVClient for audio (--vo=null)
│   └── ImagePlaybackEngine.swift    // image loading + slideshow timer
│
├── Views/
│   ├── Welcome/
│   │   └── WelcomeView.swift
│   │
│   ├── Manager/
│   │   ├── ManagerView.swift            // bridges the AppKit split shell into the WindowGroup
│   │   ├── ManagerSplitScene.swift      // NSSplitViewController + NSToolbar (scope tabs, +, actions) + ManagerChrome
│   │   ├── PlaylistSidebar.swift        // left panel: audio inlet + scope sections
│   │   ├── PlaylistCenterView.swift     // tagging counter notices + file list for the managed playlist
│   │   ├── FileCollectionView.swift     // selection/scroll over the managed playlist's list/gallery
│   │   ├── FileListView.swift           // LazyVStack-based list mode
│   │   ├── FileGalleryView.swift        // LazyVGrid-based gallery mode (visual only)
│   │   ├── FilterBar.swift              // shared filter controls (TagTokenField, saved searches, service-filter banner) targeting a given playlist's persisted filterState
│   │   ├── PlaylistTagsView.swift       // right panel's Manage Tags mode: playlist-wide rename/remove
│   │   └── TagSidebar.swift             // right panel: toggles filter+edit vs. Manage Tags mode
│   │
│   ├── Player/
│   │   ├── PlayerView.swift             // fullscreen container + overlay composition
│   │   ├── VideoPlayerView.swift        // hosts MPVVideoView via NSViewRepresentable
│   │   ├── ImagePlayerView.swift        // image display + pan/zoom
│   │   ├── PauseOverlay.swift
│   │   └── PlaybackControlsBar.swift    // bottom hover controls (both: prev/play-pause/stop/next; video: progress/scrub, volume, loop; image: slideshow toggle, interval selector)
│   │
│   ├── Audio/
│   │   ├── AudioInlet.swift             // Manager sidebar inlet + shared AudioTransport + AudioVolumeControl
│   │   └── AudioOverlay.swift           // player-mode overlay: compact transport bar + expandable lower section (LibrarySurface)
│   │
│   ├── Shared/
│   │   ├── TagEditorView.swift          // tag editor (TagTokenField, create-enabled) + invalid-name rename
│   │   ├── TagTokenField.swift          // shared multiselect-autocomplete tag control
│   │   ├── FlowLayout.swift             // wrapping chip layout
│   │   ├── FilesTagsOverlayView.swift   // visual player library overlay (wraps LibrarySurface)
│   │   ├── LibrarySurface.swift         // shared selector | files (topped by FilterBar) | tags surface (audio + visual)
│   │   ├── HoverZone.swift              // NSTrackingArea wrapper
│   │   ├── ControlButtonStyle.swift     // shared button style for the bottom bar + audio controls
│   │   ├── CloudStatusBadge.swift       // "in the cloud" / "downloading" indicator
│   │   ├── FileSelection.swift          // shared click-selection + delete-target logic (list + gallery)
│   │   └── FileRowView.swift            // single file row in list
│   │
│   └── Settings/
│       └── SettingsView.swift           // global settings (accessible via app menu)
│
├── Extensions/
│   ├── URL+MediaType.swift              // extension classification
│   └── NSWindow+Fullscreen.swift        // fullscreen helpers
│
└── Resources/
    └── Assets.xcassets

ShuTaPlaTests/                       (unit tests — Swift Testing)
├── TagParserTests.swift
├── FileSystemServiceTests.swift
├── PlaybackCoordinatorTests.swift
├── OverlayManagerTests.swift
├── HotkeyRouterTests.swift
└── CloudFileServiceTests.swift

doc/
├── features.md
└── architecture.md
```

---

## 15. Key design decisions and rationale

### Why SwiftData over plain files or Core Data

SwiftData integrates natively with SwiftUI's observation system, reducing boilerplate for reactive UI updates. The data model (playlists, file lists, preferences) maps cleanly to SwiftData's relational model. Playlist file lists can contain thousands of entries — SwiftData handles lazy loading and indexing out of the box.

### Why mpv over AVPlayer

AVPlayer cannot decode VP9 (WebM), AV1, or many container formats (MKV). Since the app's media library includes VP9 WebM files, AVPlayer would silently skip them. mpv (via ffmpeg) handles virtually every format and codec. The cost is embedding libmpv + ffmpeg + its dependency closure (~40–50 MB total), a C-to-Swift bridge layer, and managing code signing for the bundled dylibs. This is well worth it for a media player whose core job is playing files.

### Why NSEvent monitor over SwiftUI .onKeyPress

SwiftUI's `.onKeyPress` relies on view focus, which is fragile in fullscreen and when overlays appear/disappear. An `NSEvent.addLocalMonitorForEvents` captures all key events window-wide and lets us implement the priority routing described in the feature spec without worrying about focus state.

### Why NSTrackingArea over SwiftUI .onHover for edge detection

SwiftUI's `.onHover` does not fire when the cursor hits the screen edge in fullscreen — there's no "entering" a view at the edge. NSTrackingArea with `.mouseEnteredAndExited` and a thin tracking rect at each edge detects this reliably.

### Why security-scoped bookmarks

macOS sandbox (even for direct-distribution apps) requires security-scoped bookmarks to persist folder access across launches. Without them, the app would need to re-prompt for folder access every time it launches. Storing bookmark data in SwiftData alongside the playlist ensures seamless access. The app declares user-selected **read-write** file access (`ENABLE_USER_SELECTED_FILES = readwrite`), since tag edits, renames, and trashing write to the selected folders; if a saved bookmark goes stale or access is denied, `AppState.beginFolderAccess(to:)` prompts the user to relocate the folder and refreshes the bookmark.

### Why a single actor for file I/O

File system operations on the same folder must not interleave (renaming a file while scanning could produce inconsistent results). A single actor (`FileSystemService`) serializes all disk access without explicit locking, using Swift's actor model for safety.

### Why embedded value types for preferences/filters

Using separate SwiftData entities for PlaylistPreferences, FilterState, and SavedSearch would create a web of one-to-one relationships that complicate queries and cascade deletes. Embedding them as Codable structs (automatically JSON-encoded by SwiftData) keeps the model flat and makes playlist deletion clean.

---

## 16. Testing strategy

Tests use **Swift Testing** (`import Testing`) for all unit and integration tests. The `ShuTaPlaUITests` target stays on XCTest (`XCUIApplication` requires it); in v1 UI coverage comes from manual testing and Previews.

| Layer | Approach |
|-------|----------|
| **TagParser** | Parameterized tests via `@Test(arguments:)` — a single test function covers valid tags, multiple bracket groups, nested brackets, a stray unmatched bracket, empty/ineffective brackets (→ untagged), short tags, and special characters as input rows. Pure functions — no mocking needed. `#expect` for assertions, `#require` for preconditions. |
| **FileSystemService** | Integration tests using temporary directories. Create known file structures, scan, verify results. Test rename and trash operations. Use `async` test functions with `await`. |
| **PlaybackCoordinator** | Unit tests with mock engines (injected via protocol). Verify state machine transitions, mutual exclusivity rules, and suppression vs per-playlist pause (`playback = playing && !suppression`). |
| **OverlayManager** | Unit tests. Verify exclusivity rules — opening one overlay correctly closes others per spec; Compact audio may coexist with Visual Overlay; key context transfers only when fully revealed. |
| **HotkeyRouter** | Unit tests with synthetic NSEvent objects. Verify routing priority for each context (text focused, overlay open, audio holds key context vs. not, Manager arrow-key navigation — 1-D list and 2-D gallery, `[enter]` playing the selected file, `[tab]` toggling Visual Overlay, `[s]` stop, and the `[delete]` confirmation holding key context). |
| **CloudFileService** | Unit tests with a mock providing canned cloud statuses and a recording download requester. Verify status mapping, prefetch requests the next N files in order, on-demand download when playback reaches an in-cloud file, and advance-on-timeout. |
| **UI** | Manual testing and SwiftUI Previews. Snapshot tests for overlay layouts if needed. |

Services are accessed through protocols, allowing mock injection in tests. Protocol requirements are `async` to accommodate both actor-isolated and non-isolated (mock) conformers:

```swift
protocol FileSystemProviding: Sendable {
    func scanFolder(bookmark: Data) async throws -> ScanResult
    func renameFile(at url: URL, to newName: String) async throws -> URL
    // ...
}

// Actor conformance — actor isolation satisfies the async requirement naturally
extension FileSystemService: FileSystemProviding {}

// Mock for tests — struct or final class, no actor needed
struct MockFileSystem: FileSystemProviding {
    func scanFolder(bookmark: Data) async throws -> ScanResult { ... }
    func renameFile(at url: URL, to newName: String) async throws -> URL { ... }
}
```

---

## 17. Future considerations (out of scope for v1)

These are architectural hooks, not planned features. The design accommodates them without requiring structural changes:

- **Advanced filter expressions** (AND/OR per-tag, grouped expressions): The FilterState model can be extended from a flat tag list to a tree of filter nodes.
- **Multiple windows**: The single-AppState model can be expanded to per-window state if needed.
- **Drag-and-drop playlist reordering**: The `sortOrder` field on Playlist already supports this.
- **File system watching for live updates**: The one-shot re-scan on activation can be extended to continuous FSEvents/DispatchSource monitoring for real-time file changes.
- **Keyboard shortcut customization**: The HotkeyRouter's action mapping can be made configurable.
