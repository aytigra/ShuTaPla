# Manager file preview (Space-to-peek)

A quick way to see or play a single Manager file on its own — without starting
the playlist, claiming a channel, or entering fullscreen Player mode. `[space]`
on the one selected file opens a borderless, controls-free lightbox over the
window; `[space]` again (or `[esc]`) closes it.

## Goal

The point of the feature is a *peek*: look at one file in isolation, leaving the
playlist, the live audio channel, and the window mode exactly as they were.
Because it must not disturb any of that, the preview runs on its **own** playback
engine, entirely outside the `PlaybackCoordinator`'s channel bookkeeping.

## Behavior (settled)

- **Trigger** — `[space]` in Manager mode with **exactly one** file selected in a
  **video or image** playlist. Zero or multiple selection, or an audio playlist,
  is a no-op (audio is played inline in Manager already, so it needs no preview).
- **Toggle** — while the preview is open, `[space]` or `[esc]` closes it. No other
  key does anything (there are no controls); the router swallows the rest so
  nothing leaks to the file list behind the card.
- **Video** — plays from the **beginning**, **looping** forever (`loop-file=inf`,
  so it never reaches end-of-file), at the **playlist's volume**. A thin,
  non-interactive progress strip is pinned along the card's bottom edge, driven by
  the engine's `currentTime` / `duration`. No transport, no seek.
- **Image** — shown static: **no** pan/zoom and **no** `[shift]` fit-cycle. No
  progress strip.
- **Presentation** — a **floating card centered in the content area** (below the
  toolbar — the window chrome stays visible and interactive), over a dimmed
  backdrop that focuses the peek. The card is **sized to the media's aspect ratio**
  and fit within the content area minus a margin, with rounded corners. The
  backdrop is inert — dismissal is keyboard-only (`[space]`/`[esc]`). Layered by
  `RootView`, respecting the safe area so nothing draws under the toolbar buttons.
  - **Aspect source** — an image's ratio is its `NSImage.size`, known the moment it
    decodes, so the card is correctly shaped immediately. A video's ratio comes from
    mpv's decoded display size (`dwidth`/`dheight`), which is only known *after* the
    file loads; the card therefore **fades in once the size is known** rather than
    appearing at a placeholder shape and resizing.

## Design

### `MediaPreview` — the isolated preview engine owner

A new `@MainActor @Observable final class MediaPreview`, owned by `AppState`
alongside the coordinator and injected into the environment. It holds the preview
state and its own engines, deliberately separate from `PlaybackCoordinator`:

- `private(set) var file: PlaylistFile?` — the file being previewed, `nil` when
  closed. `var isOpen: Bool { file != nil }`.
- A **lazily-created video engine** built from an injectable
  `makeVideoEngine: () throws -> MPVPlaybackEngine` factory (mirrors
  `PlaybackCoordinator`, so tests substitute the window-free audio engine and
  never start real video libmpv — trap class 3). `source` is left **nil**, so
  `advanceToNext` never walks a playlist; combined with `loop-file=inf` the engine
  just plays the one file forever.
- The cheap `ImagePlaybackEngine` (no libmpv) for image files — reuses its
  off-main decode and its own per-decode scoped access.
- `folderAccess: ScopedFolderAccess` (shared with the coordinator) to open a
  scoped session on the previewed file's folder for the preview's lifetime.
- `globalSettings` is not needed; volume comes from the file's playlist
  preference.

API:

- `func toggle(_ file: PlaylistFile)` — opens the preview on `file`, or closes it
  if already open. (The `AppState` gate decides *whether* to call this.)
- `func close()` — stops the engine, ends the scoped session, clears `file`.
- `func shutdown()` — teardown for app exit / coordinator parity.

Read surface for the view: `mediaType`, the video `renderView`, the decoded
`image`, `currentTime` / `duration` (forwarded from the video engine), and
`contentSize: CGSize?` — the media's natural size for the card's aspect ratio
(`image?.size` for an image, the video engine's `videoSize` for a video, `nil`
until a video's dimensions are known).

### Video dimensions in the engine

The card's aspect ratio needs the video's decoded display size, which the engine
doesn't yet surface. Mirror the existing `time-pos` / `duration` observation:

- `MPVClient` observes mpv's `dwidth` / `dheight` (`MPV_FORMAT_INT64`, the display
  size already corrected for anamorphic pixels and rotation) and dispatches them,
  by property name, as new `MPVEvent` cases.
- `MPVPlaybackEngine` handles those events into `private(set) var videoSize: CGSize`
  (`.zero` until known), exposing `nil` when either dimension is 0 so `MediaPreview`
  can withhold the card until the shape is real.

Audio (`vo=null`) never reports these, so `videoSize` stays `.zero` there — inert.

Scoped access: the previewed playlist is the **managed** visual playlist, which in
Manager mode is always Stopped (never live), so `folderAccess.begin(for:)` /
`end(for:)` open and release a clean session that can't collide with a live
channel's. Video builds the file URL under that folder and loads with the volume
and loop set; image loads through `ImagePlaybackEngine` the same way the
coordinator's image path does.

### `AppState` gate

- `var previewFile: PlaylistFile?` mirrors `preview.file` for the view/router, or
  the router reads `preview.isOpen` directly.
- `func togglePreviewOfSelection() -> Bool` — opens only when the managed playlist
  is video/image and the (visible) selection is exactly one file; resolves that
  file and calls `preview.toggle(_:)`. Returns whether it acted (so the key
  consumes only when it does). When the preview is already open it closes it
  regardless of selection.
- `func closePreview()` — `preview.close()`.

### `HotkeyRouter` integration

In `routeManager` (and before the manager arrow/enter routing):

- If `preview.isOpen`: `[space]`/`[esc]` → `closePreview()`; **every other key is
  swallowed** (return consumed) so nothing acts behind the card.
- Else: `[space]` → `togglePreviewOfSelection()`.

The existing text-input and `hasBlockingConfirmation` guards upstream still run
first. The preview has no buttons, so it needs no `.alert` treatment — it is
driven entirely by the router, which is exactly why the open state must be
registered here so `[esc]` closes the preview instead of falling through to
Manager's `[esc]` (cancel-in-progress) and other keys don't reach the list.

### View + mount

- `MediaPreviewView` — a dimmed backdrop (`Color.black.opacity(…)`, inert) with a
  centered card floating over it. The card is sized by `.aspectRatio(contentSize,
  contentMode: .fit)` and padded in from the content-area edges, with rounded
  corners clipping its contents. Video surfaces the preview engine's `renderView`
  through a tiny `NSViewRepresentable` (like `VideoPlayerView`, but reading the
  preview engine, not the coordinator) with the progress strip along the card's
  bottom edge; an image shows `Image(nsImage:).resizable()`. The card is shown only
  once `contentSize` is known — instant for an image, one beat later for a video —
  and fades/scales in, so it never animates through an intermediate size.
- `RootView` layers `MediaPreviewView` above the mode content when `preview.isOpen`,
  **inside** the safe area so the backdrop and card stop at the toolbar rather than
  drawing under the window chrome.

## Steps (one at a time, test-first)

1. **`MediaPreview` controller** — *(done)* the type, engines,
   toggle/close/shutdown, scoped access, loop + volume + from-start.
2. **`AppState` gate** — *(done)* `togglePreviewOfSelection` / `closePreview`.
3. **`HotkeyRouter`** — *(done)* route `[space]`/`[esc]`; swallow other keys while
   open.
4. **Video dimensions** — observe `dwidth` / `dheight` in `MPVClient`, add the
   `MPVEvent` cases, fold them into `MPVPlaybackEngine.videoSize`, and expose
   `MediaPreview.contentSize`. Unit-test the event→`videoSize` mapping (feed the
   synthetic dimension events to a window-free engine; `.zero` maps to a `nil`
   `contentSize`) and the `contentSize` selection (image→`image.size`,
   video→`videoSize`).
5. **Card view + `RootView` mount** — rework `MediaPreviewView` into the
   aspect-hugging floating card over the dimmed backdrop, shown once `contentSize`
   is known; mount inside the safe area. Build + manual verification (view layer).
6. **Feature spec** — document the preview under *File interactions* in
   `doc/features/manager-mode.md`.
7. **Checklist** — navigator issues clean, dedup/simplify pass, conventions,
   writing rules.

## Testable

- Toggle opens on a file and closes on a second toggle; `close()` clears `file`
  and releases the scoped session.
- Video path sets `isLooping` and the playlist's volume; loads from position 0.
- Image path decodes and exposes an image; no progress surface.
- Selection gate: exactly-one video/image file opens; empty / multi / audio is a
  no-op.
- Router: `[space]` toggles the preview in Manager; `[esc]` closes an open
  preview; any other key is consumed (no-op) while open and doesn't reach the
  file list.
- Video dimensions: `dwidth`/`dheight` events set `videoSize`; a 0 dimension
  yields a `nil` `contentSize`. `contentSize` is the image's size for an image and
  the engine's `videoSize` for a video.
