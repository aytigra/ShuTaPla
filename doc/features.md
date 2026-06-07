# Features

## Overview

ShuTaPla is a macOS media player that works directly with files on disk. The user picks a folder, the app reads it (and its subfolders) recursively and produces a single playlist of one media type: **video**, **image**, or **audio**. Playlists are shuffled and played one file after another.

Files on disk are always the source of truth. Playlists are lightweight snapshots that hold ordering, last-played state, and per-playlist preferences — nothing more.

Filtering is driven by tags embedded in filenames. The app reads tags from names, lets the user filter by tag combinations, and can add/remove tags by renaming the actual files.

A video or image playlist can play in fullscreen while an audio playlist plays in parallel, with each playlist keeping its own volume.

## Platform and window

- macOS only.
- Single window. All playlists, overlays, and players live inside it so the user can switch seamlessly between playlists of the same or different media type without losing state.
- Fullscreen presentation for video and image playback.

## Supported file formats

The goal is good support for common formats, not exhaustive coverage.

- **Video**: mp4, webm primarily. Other common formats accepted opportunistically. HDR supported where the OS and display allow.
- **Image**: jpeg, png, jpeg xl, gif, and other common formats. HDR supported where available.
- **Audio**: mp3 primarily, plus other common formats.

Unsupported files in a selected folder are ignored silently. A small, non-intrusive notice in the playlist info area surfaces the count of skipped files so the user knows they exist without cluttering the main UI.

## First launch and creating playlists

On first launch, the main window shows a welcome state with a prominent button to add the first playlist.

A playlist can be created in three equivalent ways:

1. Welcome-state button.
2. The "+" button in the Playlists panel.
3. The application menu.

Each path opens a folder picker.

When a folder is read, the app classifies its contents:

- All-video or video-dominant → video playlist.
- All-image or image-dominant → image playlist.
- All-audio or audio-dominant → audio playlist.
- **Mixed** (for example, audio files alongside album-cover images) → the app prompts the user to choose which media type this playlist should be. Files of the other types in that folder are then treated as unsupported for this playlist.

A single folder may back multiple playlists (for instance, an audio playlist and an image playlist over the same folder).

## Playlists

Each playlist stores:

- Its origin folder path.
- The full list of files found recursively at creation time, in shuffled order.
- A display name (defaults to the folder name, can be renamed).
- Its own preferences: volume, slideshow interval, slideshow enabled, file-position persistence, image fit mode, filter state, search history (see relevant sections below).

### Reshuffle vs. Update

Each playlist exposes two refresh actions:

- **Reshuffle** — re-reads the folder and rebuilds the file list from scratch with a new random order. Last-played position is reset.
- **Update** — re-reads the folder, appends any newly discovered files at the end, and optionally prunes files that have disappeared from disk. Ordering and last-played position are preserved.

In addition, whenever a playlist becomes active the app performs an **Update** in the background (non-blocking) so new files appear without manual intervention.

### Playlist states

A playlist is always in one of three states:

- **Stopped (Manager mode)** — the default state when a playlist is selected but not playing. The main window shows the playlist's contents in Manager mode (see next section). The "active file" (last-played, or first if none) is highlighted but not playing.
- **Playing (Player mode)** — the playlist's files are being presented one after another. Video and image playlists enter **fullscreen** Player mode. Audio playlists do not change the main window; they present through the audio overlay (see Audio Player).
- **Paused** — Player mode is halted, the pause overlay is shown over the media. The window is not closed by pausing itself; only `[esc]` closes the window.

### Transitions between states

- **Selecting** a playlist in Manager mode (from the left playlists panel) puts it in **Stopped** state and shows it in the Manager view.
- **Selecting** a playlist from the Playlists overlay during Player mode immediately starts **Playing** the selected playlist.
- **Play button** (in Manager mode, or the audio player's Play control) transitions to **Playing**. Playback resumes from the playlist's last-played file. If file-position persistence is enabled for the playlist, playback also resumes from the last position within that file; otherwise it starts from the beginning of the file.
- **Double-clicking a file** in the file list (whether in Manager mode or in the Files & Tags overlay during play) transitions to **Playing** starting from that file (at its remembered position if file-position persistence is enabled, otherwise from the start).
- **`[p]` or the Pause button** transitions to **Paused**.
- **Stop button** (in the pause overlay, or in the audio player) transitions back to **Stopped** — the playlist returns to its Manager view.
- **`[esc]`** — context-dependent (see Esc behavior under Playback Controls).

### Concurrent playlists

At any time:

- At most one video playlist OR one image playlist may be in **Playing** or **Paused** state.
- At most one audio playlist may be in **Playing** or **Paused** state in parallel with the above.
- Any number of playlists may exist in **Stopped** state, but only one playlist is shown in the main window's Manager view at a time. Switching to a different playlist's Manager view does not interrupt an audio playlist that is currently Playing in parallel.

Switching to a different playlist of the same kind cleanly stops the previous one (it returns to Stopped state) and brings the new one up. In Manager mode the new playlist does **not** auto-start; it appears in its Manager view. In Player mode (via the left-hover Playlists overlay) the selected playlist starts playing immediately. Each playlist's last-played file and optional position-within-file are preserved, so returning to it later resumes where it was.

## Manager mode

Manager mode is the main-window view of a playlist when it is in the Stopped state. It is also the view the user returns to after pressing Stop.

In Manager mode, the window content is laid out as panels — no overlays are used (except the audio overlay, which operates independently).

### Layout

- **Left collapsible panel** — Playlists. Shows video and image playlists in separate sections with full management controls (create, rename, delete, reorder). At the bottom, a collapsed "Audio" section acts as a visual hint; pressing it reveals the audio overlay (see Audio Player). Selecting a playlist here opens it in Stopped state in the Manager view.
- **Center** — playlist header (name, Play button, Reshuffle / Update controls, view-mode toggle for video/image playlists), filtering controls (tag multi-select, AND/OR switch, "Untagged" option, "Invalid tagging" option, saved multi-tag searches), file list respecting the active filter, skipped-files notice, and invalid-tagging notice.
- **Right collapsible panel** — Tag management for the file(s) currently selected in the center list. Same multi-select tag input described under Tag editing UI.

### File list view modes

For video and image playlists, the file list can be shown as:

- **List** (default).
- **Gallery** with thumbnails.

The choice is persisted per playlist. Audio playlists always use list view.

### File interactions

- **Click** — select a file (also focuses it for the tag panel).
- **Double-click** — enters Player mode starting from that file (at its remembered position if file-position persistence is enabled).
- **Multi-select** — standard shift / command click to select multiple files at once. With a multi-selection:
  - **Delete** moves all selected files to the system Trash and removes them from the playlist.
  - **Tag edits in the right panel** apply to all selected files. The chips shown represent the **intersection** of tags across the selection (tags every selected file has). Adding a tag adds it to every selected file; removing a tag removes it from every selected file that has it.
- **Rename** an individual file is also available as a per-file action (context menu / inline rename).
- **Show in Finder** is available per file.

### Playlist-wide tag operations

In addition to per-file and per-selection tag editing, Manager mode exposes operations that act on **every file in the playlist**:

- **Rename a tag** across all files that have it.
- **Remove a tag** from all files that have it.

Both operations rename the underlying files on disk to match.

## Tag system

Tags are not a separate entity tracked by the app — they are literally what appears inside `[...]` in a filename. Reading tags means parsing filenames; editing tags means renaming files.

### Tag syntax in filenames

Tags live inside a single square-bracket group in the filename, e.g. `holiday clip [beach summer family].mp4`.

Rules:

- Exactly one bracket group per file. Files containing more than one bracket group are considered to have **invalid tagging** (see below) — they are not treated as untagged.
- The bracket group may appear anywhere in the filename, not only at the end.
- Tags inside the brackets are separated by spaces.
- Allowed characters per tag: letters, digits, and underscore.
- Minimum tag length: 3 characters. Shorter tokens inside the brackets are ignored.
- Tags are **case-insensitive**. They are normalized for matching and filtering but the on-disk casing is preserved when reading and writing.
- A file without any bracket group is **untagged**. "Untagged" is itself selectable as a filter option.
- Removing the last tag from a file also removes the now-empty brackets from the filename.

### Invalid tagging

A file is considered to have invalid tagging when its name has more than one bracket pair, so the app cannot unambiguously decide which group contains tags. These files are not silently ignored:

- The playlist surfaces a small indicator showing the count of files with invalid tagging.
- The file list offers a filter to show only those files, so the user can step through them and fix each one with a simple rename.
- Until fixed, an invalid-tagged file still plays normally as part of the playlist; it simply does not contribute any tags and is excluded from any tag-based filter except the "invalid tagging" filter itself.

### Tag cache

When a playlist is created (and after each Update / Reshuffle) the app collects all tags from all filenames in the playlist and caches them as the playlist's known-tags set. This drives the dropdown suggestions in the tag editor and the filter UI. Adding new tags to files also adds them to the tag cache so they appear in suggestions. Remove/rename tag playlist-wide operations also rename/remove them in the cache.

### Tag editing UI

The tag editor is used in three places: the right panel in Manager mode, the tag section of the Files & Tags overlay in Player mode, and the extended audio overlay. In all cases the UI and behavior are identical.

The tag editor applies to the **currently selected or active file(s)**. UI is a multi-select tag input:

- Existing tags appear as chips.
- A text input lets the user type freely. As they type, a dropdown shows matching existing tags and commonly used tags from the playlist's cache.

### Tag input hotkeys

When the tag input is focused, all keys are captured by the tag editor and do not trigger player or overlay actions.

| Key | Action |
|-----|--------|
| `[arrow left]` / `[arrow right]` | Move the cursor between tag chips |
| `[delete]` | Remove the tag chip to the left of the cursor |
| `[enter]` | Confirm the highlighted dropdown option, or add the typed string as a new tag |
| `[arrow up]` / `[arrow down]` | Navigate dropdown options |
| `[esc]` | Unfocus the tag input (does not close the overlay or pause) |

Adding, removing, or renaming a tag immediately renames the underlying file on disk. The playlist's reference is updated in place so play position is not lost.

## Filtering and search

The filter UI appears in the center section of Manager mode and in the Files & Tags overlay during Player mode.

### Current scope

For the first version, the filter is a single flat multi-select of tags plus an **AND / OR** switch that applies to the whole selection. "Untagged" is one of the selectable options.

Filtering affects playback: files that don't match are silently skipped during play (in addition to being hidden from the file list).

### Filter persistence and history

- Each playlist remembers its current filter selection across playlist switches, so returning to a playlist restores its filter.
- **Search history** is playlist-scoped and split into two parts:
  - **Multi-tag searches** (any AND/OR combination of two or more tags) are remembered as saved searches, listed for quick re-selection.
  - **Single-tag filters** are not stored as separate entries; instead, frequently used tags float to the top of the tag list within that playlist.

### Future direction (not in scope yet)

Per-search AND/OR toggling and grouped expressions (e.g. `A AND B AND (C OR D)`) are intended but not part of the initial version.

## Playback controls

### Esc behavior

`[esc]` has context-dependent behavior, evaluated in this priority order:

1. **Tag input is focused** → unfocuses the tag input. No other effect.
2. **An overlay is open** (Files & Tags overlay, Playlists overlay, audio overlay opened by hotkey) → closes the topmost overlay. Playback continues.
3. **Playing (no overlays open)** → pauses all active playlists and shows the pause overlay. The window stays open.
4. **Paused (no overlays open)** → closes the window. The app keeps running. Opening the window again restores the previously active playlists in their paused state, exactly as they were.
5. **Stopped / Manager mode** → closes the window. Opening it again returns to the stopped state.

The bottom playback controls bar is not considered an "overlay" for Esc purposes — it dismisses itself when the cursor leaves.

### Player mode hotkeys

These hotkeys apply during video or image playback (Playing or Paused state). When a text input (e.g. tag editor, filter search) is focused, all keys are captured by the input and do not trigger player actions.

| Key | Action |
|-----|--------|
| `[space]` | Unpause (when paused). Next file (when playing). |
| `[arrow right]` | Next file in active playlist |
| `[arrow left]` | Previous file in active playlist |
| `[arrow up]` / `[tab]` | Toggle the Files & Tags overlay (slides up from bottom) |
| `[arrow down]` | If Files & Tags overlay is open: close it. Otherwise: progressively reveal audio overlay (Hidden → Compact → Extended). |
| `[p]` | Pause all active playlists and show pause overlay |
| `[esc]` | Close overlay → pause (if playing) → close window (if paused). See Esc behavior above. |
| `[delete]` | Move the active file to the system Trash |
| `[shift]` | Cycle image fit modes: Fit → Cover → Original (image playlists only) |
| `[l]` | Toggle loop on the current file (video/audio only) |
| `[right option] + [arrow left]` | Seek −3 s (video/audio only) |
| `[right option] + [arrow right]` | Seek +3 s (video/audio only) |

**When the audio overlay is visible** (Compact or Extended), arrow keys and space switch context to the audio playlist:

| Key | Action (audio overlay visible) |
|-----|--------|
| `[arrow left]` | Previous track in audio playlist |
| `[arrow right]` | Next track in audio playlist |
| `[space]` | Unpause audio (when paused). Next audio track (when playing). |
| `[arrow up]` | Close the audio overlay to Hidden (from either Compact or Extended) |
| `[arrow down]` | Step through audio overlay states (Compact → Extended) |

### Manager mode hotkeys

In Manager mode (Stopped state), most playback hotkeys are inactive. The following apply:

| Key | Action |
|-----|--------|
| `[arrow down]` | Reveal / expand the audio overlay (same progression as Player mode) |
| `[arrow up]` | Close the audio overlay (when it is open) |
| `[esc]` | Close the window |
| `[delete]` | Move selected file(s) to the system Trash |

### Overlay interaction rules

Overlays in Player mode follow exclusivity and dismissal rules:

- **Files & Tags overlay** — while open, hover triggers for the left edge (Playlists) and bottom edge (playback controls) are suppressed. Compact audio can still appear on top (via top-edge hover or `[arrow down]`). If the audio overlay expands to Extended, the Files & Tags overlay closes automatically.
- **Extended audio overlay** — exclusive with all other overlays. Opening it closes the Files & Tags overlay and the Playlists overlay. All hover triggers are suppressed while it is shown.
- **Compact audio overlay** — closes automatically when any other hotkey-triggered overlay opens (Files & Tags via `[arrow up]`/`[tab]`, or Extended audio via `[arrow down]`).
- **Playlists overlay** (left hover) — closes on mouse leave. Also closes immediately if any overlay opens via hotkey.
- **Bottom playback controls** — auto-dismiss on mouse leave. Hover trigger is suppressed while the Files & Tags overlay is open.

### Pause overlay

Pressing `[p]` puts the active video/image playlist into **Paused** state and shows an opaque overlay on top of the media with two buttons:

- **Unpause** — resumes all playlists that were paused by this action. Note: if the audio playlist was already paused separately (via its own controls) before `[p]` was pressed, it stays paused.
- **Stop** — returns the video/image playlist to **Stopped** state (exits fullscreen Player mode, shows the playlist in Manager mode in the main window). The audio playlist has its own separate Stop control; the main Stop button does not affect it.

Pressing `[p]` or `[space]` while paused unpauses, with the same caveat about separately-paused audio.

## Video player

The video player plays files from the active video playlist one after another in fullscreen.

### Hover zones

- **Top edge** — slides in the compact audio overlay (auto-closes when the cursor leaves; see Audio Player for details).
- **Left edge** — slides in the Playlists overlay for quick playlist switching. Selecting a playlist starts playing it immediately.
- **Bottom edge** — slides in video playback controls: previous, stop, next, loop toggle, track progress / scrub, volume slider, and a **file list button** that toggles the Files & Tags overlay.

### Files & Tags overlay

Triggered by `[arrow up]`, `[tab]`, or the file list button in the bottom playback controls. Slides up from the bottom of the screen.

The overlay has two sections:

1. **File list & filtering** — the filter UI (tag multi-select, AND/OR switch, "Untagged" option, "Invalid tagging" option, saved multi-tag searches), the list of files in the active playlist (always list view, not gallery), skipped-files notice, and invalid-tagging notice.
2. **Tag management** — tag editor for the currently active file (same UI as described in Tag editing UI).

Per-file actions in the list:

- **Double-click** — jump the player to this file.
- **Rename** the file on disk (the playlist updates in place).
- **Delete** the file (moves it to the system Trash and removes it from the playlist).
- **Show in Finder**.

Multi-select is supported (shift / command click). With a multi-selection, the user can delete all selected files at once, or edit tags across the whole selection — same semantics as in Manager mode.

If a file goes missing between when the playlist was built and when playback reaches it, playback silently skips it and the file is removed from the playlist.

## Image player

The image player shows the active file of the active image playlist in fullscreen.

### Fit modes

Images are presented in **Fit** mode by default. The user can cycle through modes with `[shift]`:

- **Fit** — fit the entire image inside the window, preserving aspect ratio (letterboxed where needed).
- **Cover** — shows clipped image to fill the screen, preserving aspect ratio.
- **Original** — show the image at 1:1 pixel size.

There is no stretch / distort mode. Pan and zoom are supported in any mode using the trackpad / scroll wheel.

### Slideshow

When slideshow mode is on (by default it is off, configurable per playlist), the player advances to the next file after the configured interval. When off, the current image is shown indefinitely until the user advances manually.

Slideshow interval is configurable both globally and per playlist; the per-playlist value, when set, overrides the global default.

### Hover zones

- **Top edge** — slides in the compact audio overlay (same behavior as video player).
- **Left edge** — slides in the Playlists overlay for quick playlist switching.
- **Bottom edge** — slides in image playback controls: previous, stop, next, slideshow on/off toggle, slideshow interval selector, and a **file list button** that toggles the Files & Tags overlay.

The Files & Tags overlay works identically to the video player's (see above).

## Audio player

Audio playlists use the same folder / shuffle / tag model as the other types but present themselves through a compact and extended overlay rather than fullscreen presentation.

### Audio overlay states

1. **Hidden** (default) — nothing is shown for audio.
2. **Compact** — shows current track and basic playback controls (play/pause, previous, next, stop, track progress / scrub, volume, loop toggle). Appears via:
   - **Hovering** over the top edge of the screen — auto-closes when the cursor leaves the overlay area.
   - **`[arrow down]`** from Hidden — stays open until explicitly closed. Does not auto-close on mouse leave; closes on click outside or `[arrow up]`.
3. **Extended** — expands the compact view to include: audio-only playlist selector, active playlist's file list with filtering, and tag management for the current track. Playback controls remain visible. This effectively serves as a manager view for audio playlists that works during playback.

### Navigation between states

- `[arrow down]` steps forward: Hidden → Compact → Extended.
- `[arrow up]` closes the audio overlay back to Hidden from either Compact or Extended.

### Audio controls

The compact and extended audio UI exposes:

- Play / pause (audio only — separate from the global `[p]` pause).
- Previous / next track.
- Stop (returns the audio playlist to Stopped state without affecting the video/image playlist).
- Volume slider (per-playlist, persisted).
- Track progress / scrub.
- Loop toggle — loop current file indefinitely, until un-looped or manually navigated to next file.

### Audio in parallel with video / image

When an audio playlist plays alongside a video, the audio is **mixed** with the video's own audio (the video is not muted). Each playlist keeps and persists its own volume level, so the user balances the mix once and the setting sticks for future sessions.

## Playlists overlay (Player mode)

Triggered by hovering over the left edge during video or image playback.

This is a simplified playlist selector — it shows video and image playlists in separate sections but does **not** expose full management controls (no create, rename, delete, or reorder). Its purpose is quick switching: selecting a playlist immediately starts playing it.

At the bottom, a collapsed "Audio" section acts as a visual hint. Pressing it reveals the extended audio overlay with its own playlist controls.

Full playlist management (create, rename, delete, reorder) is available only in Manager mode via the left collapsible panel.

## Settings and persistence

### Global settings

- Default slideshow interval.
- Default file-position persistence behavior (whether playlists resume mid-file by default).
- Default image fit mode.

### Per-playlist preferences (override global where applicable)

- Slideshow interval (image only).
- Slideshow enabled (image only).
- Image fit mode (image only).
- File-position persistence on/off (video/audio only).
- Volume (video/audio only).
- Filter state and saved searches.
- Frequently-used-tag ordering.
- Manager-mode file list view: list vs. gallery (video and image playlists only).

### App state persisted across launches

- Active video / image / audio playlists.
- Last-played file in each playlist.
- Last-played position within file, when file-position persistence is enabled for that playlist.
- Whether playback is paused (so reopening after `[esc]` resumes the prior paused state).
- Window placement (best-effort).
