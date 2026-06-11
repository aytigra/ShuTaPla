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
| Video playback | mpv (libmpv) | Embedded as a dynamic library. Renders via Vulkan (MoltenVK → Metal) into a CAMetalLayer-backed NSView. Handles VP9 WebM, MKV, and all common containers/codecs. |
| Audio playback | mpv (libmpv) | Second independent mpv instance for audio. Mixed output at the OS level (macOS CoreAudio handles concurrent output devices). |
| Image display | Core Graphics + SwiftUI | CGImageSource for efficient loading/thumbnailing. Custom view for pan/zoom. HDR via NSImage with EDR support. |
| File system | Foundation (FileManager, URL) | Recursive enumeration, rename, trash. Security-scoped bookmarks for persistent folder access. |
| File re-scan | Foundation (FileManager) | One-shot re-scan on playlist activation to detect new/removed files. No continuous watching in v1. |
| Cloud files | Foundation (NSMetadataQuery, FileManager ubiquitous APIs) | Detect iCloud/offline placeholder state per file; request on-demand downloads and prefetch the next files in playback order. |
| Concurrency | Swift Concurrency | async/await, actors for serialized file I/O, TaskGroups for parallel thumbnail generation. |
| Minimum deployment | macOS 26.4 | |

### mpv integration approach

mpv is embedded as **libmpv** (dynamic library, `libmpv.dylib`) built via Homebrew or from source with `--enable-libmpv-shared`. The app ships the dylib inside the app bundle's `Frameworks/` directory.

**Rendering pipeline**: mpv is configured with `--vo=gpu-next --gpu-api=vulkan --gpu-context=moltenvk`. MoltenVK translates Vulkan calls to Metal, so mpv renders through the Metal driver without using the deprecated OpenGL API. The `MPVMetalView` (an `NSView` subclass) hosts a `CAMetalLayer` and uses mpv's render API (`mpv_render_context`) to present decoded frames. This NSView is bridged into SwiftUI via `NSViewRepresentable`. MoltenVK (`libMoltenVK.dylib`) is bundled alongside libmpv in the app's `Frameworks/` directory.

**C-to-Swift bridge**: libmpv exposes a C API. The app uses a thin Swift wrapper (`MPVClient`) that:
- Manages the `mpv_handle` lifecycle (create/destroy).
- Serializes all `mpv_command`/`mpv_set_property`/`mpv_observe_property` calls through a dedicated serial `DispatchQueue`. mpv's C API is not thread-safe — all calls to a given `mpv_handle` must be serialized.
- Sends commands via `mpv_command_async` (load file, seek, pause, etc.).
- Observes properties via `mpv_observe_property` (time-pos, duration, pause, eof-reached, etc.).
- Receives events via a callback that posts to an `AsyncStream<MPVEvent>`, consumed on MainActor for UI updates.

**Two-instance architecture**: Video and audio use **separate `mpv_handle` instances**. Each instance has independent state (volume, position, pause). macOS CoreAudio automatically mixes the output of both instances — no additional audio session configuration needed.

**Build and distribution**: The `libmpv.dylib`, `libMoltenVK.dylib`, and their dependencies (e.g., ffmpeg libs) are embedded in the app bundle and code-signed. For notarization, all embedded dylibs must have valid signatures. The Xcode build phase copies and signs them automatically.

**HDR**: mpv handles HDR tone-mapping natively. With Vulkan/MoltenVK rendering, HDR pass-through to EDR-capable displays works via mpv's `--target-colorspace-hint` and the Metal layer's `wantsExtendedDynamicRangeContent = true`.

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
 ├── currentFileIndex: Int             // index into the unfiltered file list
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
 ├── filterState: FilterState          // embedded value
 │    ├── selectedTags: [String]
 │    ├── filterMode: FilterMode       // .and | .or
 │    ├── includeUntagged: Bool
 │    └── showInvalidTagging: Bool
 │
 ├── savedSearches: [SavedSearch]      // embedded array of value types
 │    └── each: { tags: [String], mode: FilterMode }
 │
 ├── tagFrequency: [String: Int]       // per-playlist tag usage counts
 │
 └── files: [PlaylistFile]             // @Relationship, cascade delete
      ├── id: UUID
      ├── relativePath: String         // relative to playlist folder
      ├── fileName: String             // just the filename component
      ├── tags: [String]               // parsed from filename, cached
      ├── taggingStatus: TaggingStatus // .valid | .untagged | .invalid
      ├── lastPosition: TimeInterval?  // for file-position persistence
      ├── sortOrder: Int               // shuffled order within playlist
      └── (runtime) cloudStatus: CloudStatus  // not persisted — derived from disk each scan/observation

AppState (singleton, persisted)
 ├── activeVideoPlaylistId: UUID?
 ├── activeImagePlaylistId: UUID?
 ├── activeAudioPlaylistId: UUID?
 ├── globalPaused: Bool                 // window closed while globally paused ([p]/[esc])
 ├── videoImagePausedSeparately: Bool   // paused via its own control — stays paused on reopen
 ├── audioPausedSeparately: Bool        // audio paused via its own control — stays paused
 ├── slideshowPausedSeparately: Bool    // slideshow paused via its own control — stays paused
 └── windowFrame: Data?               // encoded NSRect
```

**Singleton pattern**: SwiftData has no built-in singleton mechanism. `AppStateModel` and `GlobalSettings` use a fetch-or-create pattern: on launch, fetch with `FetchDescriptor` (limit 1). If no result, insert a new instance with defaults. All access goes through a computed property on the app's container or state object that caches the fetched instance.

### Design decisions

- **PlaylistPreferences as an embedded value type** (Swift `Codable` struct stored as a SwiftData property — SwiftData automatically encodes/decodes Codable types to JSON), not a separate SwiftData entity. Avoids join overhead and simplifies cascade — deleting a playlist deletes its preferences automatically.
- **FilterState and SavedSearch as embedded values** for the same reason.
- **Security-scoped bookmarks** (`folderBookmark: Data`) are essential. A plain file path loses access after app restart on sandboxed macOS. On folder selection, the app creates a bookmark; on access, it resolves the bookmark and starts/stops security-scoped access.
- **Relative paths in PlaylistFile** — stored relative to the playlist's root folder so that if the folder is moved and the bookmark is updated, file references remain valid.
- **Tag data is denormalized** — tags are stored both per-file (as parsed arrays) and aggregated per-playlist (as `tagFrequency`). The per-file data is the cache; the per-playlist frequency drives UI ordering in filter/editor dropdowns.

### Enums

```swift
enum MediaType: String, Codable, Sendable { case video, image, audio }
enum ImageFitMode: String, Codable, Sendable { case fit, cover, original }
enum ViewMode: String, Codable, Sendable { case list, gallery }
enum FilterMode: String, Codable, Sendable { case and, or }
enum TaggingStatus: String, Codable, Sendable { case valid, untagged, invalid }
enum CloudStatus: String, Sendable { case local, inCloud, downloading }   // runtime only, not persisted
```

### Sendable conformance

Types that cross isolation boundaries (e.g., from `FileSystemActor` to `@MainActor`) must be `Sendable`:

- **`ScanResult`, `UpdateDelta`, `TagParseResult`** — value types returned from `FileSystemActor`. Conform to `Sendable` naturally as structs with Sendable fields.
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
                    ┌─────────────────────┐
                    │     AppState        │  (persisted singleton)
                    │  active playlist IDs│
                    └────────┬────────────┘
                             │ references
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
   │PlaybackCoord.│ │ OverlayMgr   │ │  HotkeyRouter│
   │              │ │              │ │              │
   │ videoPlayer  │ │ filesTagsOpen│ │ resolves key │
   │ audioPlayer  │ │ audioState   │ │ to action    │
   │ imageTimer   │ │ playlistsOpen│ │ based on     │
   │ playback     │ │ pauseShown   │ │ current      │
   │ state per    │ │ exclusivity  │ │ focus +      │
   │ playlist     │ │ rules        │ │ overlay      │
   └──────────────┘ └──────────────┘ └──────────────┘
```

#### AppState

`@MainActor @Observable final class`. Injected into the SwiftUI environment via `.environment(appState)` at the scene level and consumed in views via `@Environment(AppState.self) private var appState`. Holds references to the SwiftData model context and the active playlist models. Responsible for:
- Tracking which playlists are active (by media category).
- Persisting active-playlist IDs and paused state to the SwiftData `AppState` singleton on change.
- Providing the current app mode (`.welcome`, `.manager`, `.player`).
- Computing filtered file lists as cached properties (not inline `.filter {}` in ForEach). When `FilterState` or the file list changes, the filtered array is recomputed and stored. Views bind to the precomputed array for optimal ForEach diffing.

#### PlaybackCoordinator

Owns both mpv instances (video, audio) and the image slideshow timer. Enforces concurrency rules:
- At most one video **or** image playlist playing at a time.
- At most one audio playlist playing in parallel.
- Stopping one playlist does not affect the other channel.

Exposes playback state (playing/paused/stopped, current time, duration) as observable properties for UI binding.

#### OverlayManager

Tracks visibility of all overlays in Player mode and enforces exclusivity rules from the feature spec:
- Extended audio is exclusive — opening it closes Files & Tags and Playlists.
- Compact audio closes when a *hotkey-triggered* overlay opens, but may re-appear on top of an open Files & Tags overlay when summoned by top-edge hover.
- Files & Tags suppresses hover triggers for Playlists and bottom controls; it closes automatically only when Extended audio opens.
- Owns **key context** — which target (player vs. audio overlay) currently receives arrow/space/loop/seek. The audio overlay claims key context only once it is *fully revealed* (slide-in animation complete) and returns it to the player when it closes to Hidden.

State is an enum set, not a stack — overlays don't nest arbitrarily.

#### HotkeyRouter

Receives raw key events and routes them to the appropriate handler based on:
1. Is a text input focused? → swallow the event (the field handles it).
2. Is it `[esc]`? → apply the esc priority chain (unfocus input → close overlay → pause → close window).
3. Does the audio overlay hold **key context** (fully revealed)? → route arrow/space/loop/seek to audio controls.
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
          │              │ pause [p]     │
          │              │               │
          │         ┌────▼─────┐         │
          └─────────│ Paused   │─────────┘
            unpause └──────────┘
```

State is stored on the runtime `PlaybackCoordinator`, not on the SwiftData model. On window close or app quit, the coordinator records to the persisted `AppState` both whether playback was *globally* paused (`[p]`/`[esc]`) and which channels were paused *separately* via their own controls. Channels paused separately stay paused on reopen; a global pause is restored as a global pause and is not promoted to a per-channel separate pause.

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

```
Responsibilities:
  - Generate thumbnails for video files (mpv screenshot command, or ffmpeg via libmpv).
  - Generate thumbnails for image files (CGImageSource with kCGImageSourceThumbnailMaxPixelSize).
  - Cache thumbnails in memory (NSCache) and on disk (Caches directory).
  - Provide async thumbnail loading for gallery view.

Key methods:
  thumbnail(for file: PlaylistFile, in playlist: Playlist, size: CGSize) async -> NSImage?
```

Thumbnails are generated lazily on first request and cached. Cache key is `file relativePath + modification date` so stale thumbnails are invalidated.

### BookmarkService

```
Responsibilities:
  - Create security-scoped bookmarks from user-selected folder URLs.
  - Resolve bookmarks back to URLs with security-scoped access.
  - Track active access sessions (startAccessingSecurityScopedResource / stop).
  - Handle stale bookmarks (re-prompt user if bookmark can no longer be resolved).

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

    var body: some Scene {
        WindowGroup {
            switch appState.mode {
            case .welcome:    WelcomeView()
            case .manager:    ManagerView()
            case .player:     PlayerView()
            }
            .environment(appState)
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
┌──────────────────────────────────────────────────────────┐
│  ┌──────────┐  ┌─────────────────────────┐  ┌─────────┐ │
│  │          │  │                         │  │         │ │
│  │ Playlists│  │  Playlist header        │  │  Tag    │ │
│  │ panel    │  │  Filter controls        │  │  panel  │ │
│  │          │  │  File list / gallery    │  │         │ │
│  │ (collaps-│  │                         │  │ (collaps│ │
│  │  ible)   │  │                         │  │  -ible) │ │
│  │          │  │                         │  │         │ │
│  └──────────┘  └─────────────────────────┘  └─────────┘ │
└──────────────────────────────────────────────────────────┘
```

Implemented as a custom three-column layout using `HSplitView` with collapsible side panels. `NavigationSplitView` is not used — its fixed column semantics and limited width control don't suit a media manager with independently collapsible panels. The left and right panels have toggle buttons to collapse/expand, with animated width transitions. `HSplitView` does not natively support collapsing — the collapse is implemented by conditionally setting the panel's frame width to zero (or removing its content) and animating the transition with `withAnimation`.

**Playlists panel structure**: The left panel groups playlists into sections by media type — **Video**, **Image** — each with full management controls (create, rename, delete, reorder via drag). At the bottom, a collapsed **Audio** section acts as a visual hint; clicking it opens the audio overlay (compact or extended). Playlists are rendered from a `@Query` in the view (not inside `@Observable` classes, where `@Query` would conflict with the `@Observable` macro — `@ObservationIgnored` would be required), filtered by `mediaType`, sorted by `sortOrder`.

**Playlists overlay (Player mode)**: The left-hover overlay in Player mode mirrors this section structure but is read-only — no create/rename/delete/reorder. Selecting a playlist immediately starts playing it. The bottom Audio hint opens the extended audio overlay.

### Player mode layout

```
┌──────────────────────────────────────────────────────────┐
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ top hover zone ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
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
│ e     │  Files & Tags overlay (when visible)        │  ▓ │
│ r     │  slides up from bottom                      │  ▓ │
│       └─────────────────────────────────────────────┘  ▓ │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ bottom hover zone ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
└──────────────────────────────────────────────────────────┘
```

**Hover zones** are implemented using `NSTrackingArea` (via an NSView bridge) rather than SwiftUI `.onHover`, which doesn't reliably detect edge-of-screen hover in fullscreen. Each zone has a thin invisible tracking area along the window edge.

**Overlay rendering**: Overlays are SwiftUI views composed via `.overlay()` and `.transition()` modifiers on the PlayerView, controlled by the OverlayManager's observable state. Overlay show/hide uses `withAnimation` (event-driven) rather than the deprecated `.animation()` without a value parameter. Transitions use `.move(edge:)` or `.opacity` paired with the `withAnimation` block in the OverlayManager's `show()`/`hide()` methods.

### Overlay exclusivity implementation

The OverlayManager maintains a set of active overlays and enforces rules declaratively:

```swift
enum Overlay: Hashable {
    case filesTags
    case playlistsSidebar
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
            active.remove(.playlistsSidebar)
            active.remove(.audioCompact)
            active.remove(.bottomControls)
        case .filesTags:                     // hotkey overlay — closes compact audio + hover overlays
            active.remove(.audioCompact)
            active.remove(.playlistsSidebar)
            active.remove(.bottomControls)
        case .audioCompact:
            // Compact audio may sit on top of an open Files & Tags overlay (top-edge hover),
            // so it does NOT close it. It only yields to Extended audio (handled above).
            break
        case .playlistsSidebar, .bottomControls:
            // Hover overlays are suppressed while Files & Tags or Extended audio is open.
            if active.contains(.filesTags) || active.contains(.audioExtended) { return }
        case .pauseOverlay:
            break
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

Both manual and automatic Update prune files that have disappeared from disk. Every re-read (Reshuffle and Update, manual or automatic) runs as a background Task with a small "sync in progress" indicator shown while it is running — the UI is never blocked.

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
  ├── renderView: MPVMetalView       (NSView subclass, hosted via NSViewRepresentable)
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
- If the playlist has a filter active, the coordinator walks the unfiltered file list by `sortOrder`, skipping files whose tags don't match `FilterState`. `currentFileIndex` always refers to the unfiltered list so that disabling the filter restores the full sequence without losing position.
- On each advance the coordinator triggers cloud prefetch for the upcoming files (see PlaybackCoordinator orchestration → Cloud prefetch).

**HDR**: mpv handles HDR natively. With Vulkan/MoltenVK rendering, EDR pass-through is supported via mpv's `--target-colorspace-hint=yes`. The `CAMetalLayer`'s `wantsExtendedDynamicRangeContent` is set to `true` to enable HDR output on capable displays.

**MPVMetalView**: A custom `NSView` subclass that hosts a `CAMetalLayer`. mpv renders via Vulkan (MoltenVK translates to Metal internally). The view provides the `CAMetalLayer` as the rendering surface and handles resize/display-change notifications. Wrapped in `NSViewRepresentable` for SwiftUI embedding.

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
    
    // Global pause ([p] key) affects video/image + audio
    // But tracks which audio was already paused to avoid unpausing it
    func pauseAll() { ... }
    func unpauseAll() { ... }
}
```

**Cloud prefetch**: On each file change (and when a playlist starts), the coordinator asks the `CloudFileService` to prefetch the next files in playback order, so they are local before playback reaches them. If the file playback is about to reach is still in the cloud, the coordinator requests its download immediately and the row shows the downloading indicator; if it cannot be made local in time, the same "advance to the next available file" rule used for missing files applies.

---

## 9. Hotkey system

### Architecture

Key events are captured at the NSWindow level via `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`. This approach:
- Works in fullscreen (unlike SwiftUI `.onKeyPress` which can lose focus).
- Intercepts events before they reach SwiftUI's responder chain.
- Allows the HotkeyRouter to decide routing before any view sees the event.

### Routing priority

```
Key event arrives
       │
       ▼
  1. Is a text field first responder? (tag input, rename field, filter search)
     YES → pass through to text field. Return nil (event consumed by field).
     NO  → continue.
       │
       ▼
  2. Is it [esc]? → Apply esc priority chain:
     a. Tag input focused → unfocus
     b. Overlay open → close topmost
     c. Playing → pause
     d. Paused → close window
     e. Manager → close window
       │
       ▼
  3. Is it [space]?
     → If paused: unpause all (same as pressing Unpause in pause overlay).
     → If playing: advance to next file in active playlist.
     → If the audio overlay holds key context: applies to the audio playlist instead of video/image.
       │
       ▼
  4. Does the audio overlay hold key context (revealed AND fully animated in)?
     YES → route arrow keys, [space], [l], and seek to audio controls.
     NO  → continue.
       │
       ▼
  5. Is app in Player mode?
     YES → player hotkey table ([tab]/[arrow up] open Files & Tags; [arrow down]
           closes it or reveals Compact audio).
     NO  → manager hotkey table (arrow up/down = file-list navigation; the audio
           overlay is opened by hover or the Audio section, not by arrows).
```

### Modifier key handling

`[right option] + arrow` for seeking requires detecting the right Option key specifically. This is done by checking `event.modifierFlags` for `.option` and `event.keyCode` for the right-side Option key code (61).

`[shift]` for fit mode cycling checks `event.modifierFlags.contains(.shift)`.

---

## 10. Concurrency model

### Actor boundaries

```swift
actor FileSystemActor {
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
    let result = await fileSystemActor.scanFolder(bookmark: playlist.folderBookmark)
    // Back on MainActor — safe to update SwiftData and UI state
    playlist.files = result.files
}
```

### Background tasks

| Operation | Approach |
|-----------|----------|
| Folder scan (create/reshuffle) | Structured Task, shows progress indicator |
| Auto-update on playlist activation | Structured `Task` from `@MainActor` context; the `await fileSystemActor.scanFolder(...)` call hops off MainActor naturally via actor isolation. Non-blocking — results merged on return. |
| Thumbnail generation | TaskGroup, parallel per-file, cancellable on scroll |
| File rename (tag edit) | Inline await on FileSystemActor, fast enough to feel synchronous |
| Batch tag rename/remove | Structured Task with progress, cancellable |

---

## 11. Persistence and lifecycle

### What is persisted and where

| Data | Storage | When written |
|------|---------|-------------|
| Playlists, files, preferences | SwiftData | On every mutation (SwiftData auto-save) |
| Active playlist IDs | SwiftData (AppState) | On playlist activation/deactivation |
| Paused state | SwiftData (AppState) | On pause/unpause and window close. Records the global paused flag plus per-channel "paused separately" flags (video/image, audio, slideshow). |
| Last-played file index | SwiftData (Playlist) | On file advance |
| File position within file | SwiftData (PlaylistFile) | Only when `playlist.preferences.filePositionPersistence` is enabled. Written periodically (every 5s) during playback and on file change/stop. |
| Window frame | SwiftData (AppState) | On window move/resize (debounced) |
| Security-scoped bookmarks | SwiftData (Playlist) | On playlist creation |
| Thumbnail cache | File system (Caches dir) | On generation |

### App lifecycle events

- **Launch**: Load AppState from SwiftData. Reconstruct PlaybackCoordinator state. Restore each channel's paused state — channels paused separately stay paused; a recorded global pause is restored as a global pause. Restore window frame.
- **Window close** (not quit): Persist current state. Record whether playback was globally paused and which channels were paused separately. Pause active playlists.
- **Window reopen**: Restore paused state exactly as it was — separately-paused channels are not auto-unpaused.
- **App termination**: Final persist of all playback positions and state.
- **Folder becomes inaccessible** (bookmark stale): Surface error in playlist header with option to re-select folder.

---

## 12. Error handling strategy

| Scenario | Behavior |
|----------|----------|
| File missing during playback | Skip silently, remove from playlist, advance to next. |
| File missing during scan/update | Prune from playlist (Update mode) or don't include (Reshuffle). |
| Corrupt/unplayable media file | Skip, advance to next. Increment skipped-files count. |
| Folder access lost (stale bookmark) | Show inline error on playlist. Offer to re-select folder. |
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
- Files & Tags overlay file list follows the same patterns as Manager mode.

### General

- Use `@ScaledMetric` for custom spacing/sizing that should respect Dynamic Type.
- Semantic fonts (`.body`, `.headline`) are used throughout — no hardcoded font sizes.
- Semantic colors (`.primary`, `.secondary`, `.background`) are used for automatic light/dark mode support.

---

## 14. Directory structure

```
ShuTaPla/
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
│   └── ThumbnailService.swift       // async thumbnail generation + caching
│
├── MPV/
│   ├── MPVClient.swift              // Swift wrapper around mpv_handle (C API)
│   ├── MPVMetalView.swift           // NSView subclass with CAMetalLayer for mpv rendering
│   ├── MPVEvent.swift               // Swift enum mapping mpv events
│   └── mpv-bridging.h               // C bridging header for libmpv
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
│   │   ├── ManagerView.swift            // three-panel layout
│   │   ├── PlaylistSidebar.swift        // left panel
│   │   ├── PlaylistCenterView.swift     // header + filter + file list
│   │   ├── FileListView.swift           // LazyVStack-based list mode
│   │   ├── FileGalleryView.swift        // LazyVGrid-based gallery mode
│   │   ├── FilterBar.swift              // tag filter controls
│   │   └── TagSidebar.swift             // right panel
│   │
│   ├── Player/
│   │   ├── PlayerView.swift             // fullscreen container + overlay composition
│   │   ├── VideoPlayerView.swift        // hosts MPVMetalView via NSViewRepresentable
│   │   ├── ImagePlayerView.swift        // image display + pan/zoom
│   │   ├── PauseOverlay.swift
│   │   ├── PlaybackControlsBar.swift    // bottom hover controls (video: progress/scrub, volume, loop; image: slideshow toggle, interval selector)
│   │   └── PlaylistsOverlay.swift       // left hover playlist selector
│   │
│   ├── Audio/
│   │   ├── AudioOverlayCompact.swift
│   │   └── AudioOverlayExtended.swift
│   │
│   ├── Shared/
│   │   ├── TagEditorView.swift          // multi-select chip input
│   │   ├── FilesTagsOverlayView.swift   // used in both video and image player
│   │   ├── HoverZone.swift              // NSTrackingArea wrapper
│   │   ├── CloudStatusBadge.swift       // "in the cloud" / "downloading" indicator
│   │   └── FileRowView.swift            // single file row in list
│   │
│   └── Settings/
│       └── SettingsView.swift           // global settings (accessible via app menu)
│
├── Extensions/
│   ├── URL+MediaType.swift              // extension classification
│   └── NSWindow+Fullscreen.swift        // fullscreen helpers
│
├── Resources/
│   └── Assets.xcassets
│
├── Tests/
│   ├── TagParserTests.swift
│   ├── FileSystemServiceTests.swift
│   ├── PlaybackCoordinatorTests.swift
│   ├── OverlayManagerTests.swift
│   ├── HotkeyRouterTests.swift
│   └── CloudFileServiceTests.swift
│
└── doc/
    ├── features.md
    └── architecture.md
```

---

## 15. Key design decisions and rationale

### Why SwiftData over plain files or Core Data

SwiftData integrates natively with SwiftUI's observation system, reducing boilerplate for reactive UI updates. The data model (playlists, file lists, preferences) maps cleanly to SwiftData's relational model. Playlist file lists can contain thousands of entries — SwiftData handles lazy loading and indexing out of the box.

### Why mpv over AVPlayer

AVPlayer cannot decode VP9 (WebM), AV1, or many container formats (MKV). Since the app's media library includes VP9 WebM files, AVPlayer would silently skip them. mpv (via ffmpeg) handles virtually every format and codec. The cost is embedding libmpv + MoltenVK + ffmpeg (~40–50 MB total), a C-to-Swift bridge layer, and managing code signing for the bundled dylibs. This is well worth it for a media player whose core job is playing files.

### Why NSEvent monitor over SwiftUI .onKeyPress

SwiftUI's `.onKeyPress` relies on view focus, which is fragile in fullscreen and when overlays appear/disappear. An `NSEvent.addLocalMonitorForEvents` captures all key events window-wide and lets us implement the priority routing described in the feature spec without worrying about focus state.

### Why NSTrackingArea over SwiftUI .onHover for edge detection

SwiftUI's `.onHover` does not fire when the cursor hits the screen edge in fullscreen — there's no "entering" a view at the edge. NSTrackingArea with `.mouseEnteredAndExited` and a thin tracking rect at each edge detects this reliably.

### Why security-scoped bookmarks

macOS sandbox (even for direct-distribution apps) requires security-scoped bookmarks to persist folder access across launches. Without them, the app would need to re-prompt for folder access every time it launches. Storing bookmark data in SwiftData alongside the playlist ensures seamless access.

### Why a single actor for file I/O

File system operations on the same folder must not interleave (renaming a file while scanning could produce inconsistent results). A single `FileSystemActor` serializes all disk access without explicit locking, using Swift's actor model for safety.

### Why embedded value types for preferences/filters

Using separate SwiftData entities for PlaylistPreferences, FilterState, and SavedSearch would create a web of one-to-one relationships that complicate queries and cascade deletes. Embedding them as Codable structs (automatically JSON-encoded by SwiftData) keeps the model flat and makes playlist deletion clean.

---

## 16. Testing strategy

Tests use **Swift Testing** (`import Testing`) as the primary framework. XCTest is not used — there is no UI automation or performance measurement in v1 that requires it.

| Layer | Approach |
|-------|----------|
| **TagParser** | Parameterized tests via `@Test(arguments:)` — a single test function covers valid tags, multiple bracket groups, nested brackets, a stray unmatched bracket, empty/ineffective brackets (→ untagged), short tags, and special characters as input rows. Pure functions — no mocking needed. `#expect` for assertions, `#require` for preconditions. |
| **FileSystemService** | Integration tests using temporary directories. Create known file structures, scan, verify results. Test rename and trash operations. Use `async` test functions with `await`. |
| **PlaybackCoordinator** | Unit tests with mock engines (injected via protocol). Verify state machine transitions, mutual exclusivity rules, pause/unpause semantics. |
| **OverlayManager** | Unit tests. Verify exclusivity rules — opening one overlay correctly closes others per spec; Compact audio may coexist with Files & Tags; key context transfers only when fully revealed. |
| **HotkeyRouter** | Unit tests with synthetic NSEvent objects. Verify routing priority for each context (text focused, overlay open, audio holds key context vs. not, Manager arrow-key list navigation, `[tab]` opens Files & Tags). |
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
extension FileSystemActor: FileSystemProviding {}

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
