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
2. The "+" button in the Playlists overlay.
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

- **Selecting** a playlist (from the Playlists overlay or welcome screen) puts it in **Stopped** state and shows it in the main window's Manager view.
- **Play button** (in Manager mode, or the audio player's Play control) transitions to **Playing**. Playback resumes from the playlist's last-remembered position, or from the first file if there is no remembered position.
- **Double-clicking a file** in the file list (whether in Manager mode or in the Playlist Files overlay during play) transitions to **Playing** starting from that file at its remembered position (or from its start if none).
- **`[p]` or the Pause button** transitions to **Paused**.
- **Stop button** (in the pause overlay, or in the audio player) transitions back to **Stopped** — the playlist returns to its Manager view.
- **`[esc]`** pauses and closes the window. Reopening restores the prior state.

### Concurrent playlists

At any time:

- At most one video playlist OR one image playlist may be in **Playing** or **Paused** state.
- At most one audio playlist may be in **Playing** or **Paused** state in parallel with the above.
- Any number of playlists may exist in **Stopped** state, but only one playlist is shown in the main window's Manager view at a time. Switching to a different playlist's Manager view does not interrupt an audio playlist that is currently Playing in parallel.

Switching to a different playlist of the same kind cleanly stops the previous one (it returns to Stopped state) and brings the new one up. The new playlist does **not** auto-start; it appears in its Manager view (or in the audio overlay for audio), and the user presses Play (or double-clicks a file) to begin playback. Each playlist's last-played file and optional position-within-file are preserved, so returning to it later resumes where it was.

## Manager mode

Manager mode is the main-window view of a playlist when it is in the Stopped state. It is also the view the user returns to after pressing Stop in the pause overlay.

### Layout

- **Header** — playlist name, Play button, Reshuffle and Update controls, filter UI (same controls as the Playlist Files overlay, see Filtering and search), and a view-mode toggle for video and image playlists.
- **Center** — file list, respecting the active filter.
- **Right** — collapsible tag panel (the same multi-select tag input described in the Tag manager overlay). The panel applies to the file(s) currently selected in the list.

### File list view modes

For video and image playlists, the file list can be shown as:

- **List** (default).
- **Gallery** with thumbnails.

The choice is persisted per playlist. Audio playlists always use list view.

### File interactions

- **Click** — select a file (also focuses it for the tag panel).
- **Double-click** — enters Player mode starting from that file at its remembered position.
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
- The Playlist Files overlay offers a filter to show only those files, so the user can step through them and fix each one with a simple rename (either through the file overlay's rename action or by editing the file on disk).
- Until fixed, an invalid-tagged file still plays normally as part of the playlist; it simply does not contribute any tags and is excluded from any tag-based filter except the "invalid tagging" filter itself.

### Tag cache

When a playlist is created (and after each Update / Reshuffle) the app collects all tags from all filenames in the playlist and caches them as the playlist's known-tags set. This drives the dropdown suggestions in the tag manager and the filter UI. Adding new tags to files also adds them to tag cache so they appear in suggestions. Remove/rename tag playlist-wide operations also rename/remove them in cache.

### Tag manager overlay in play mode

The tag manager applies to the **currently active file**. It is summoned by hovering over the right of the screen or by pressing `[arrow left]`, shown alongside file list.

UI is a multi-select tag input:

- Existing tags appear as chips.
- A text input lets the user type freely. As they type, a dropdown shows matching existing tags and commonly used tags from the playlist's cache.

Keyboard behavior inside the tag input:

- `[arrow left]` / `[arrow right]` — move the cursor between tag chips.
- `[delete]` — removes the tag chip to the left of the cursor.
- `[enter]` — confirms the highlighted dropdown option, or adds the currently typed string as a new tag if it isn't already in the list.
- `[arrow up]` / `[arrow down]` — navigate dropdown options.

Adding, removing, or renaming a tag immediately renames the underlying file on disk. The playlist's reference is updated in place so play position is not lost.

The audio player does not currently offer a tag manager.

## Filtering and search

The filter UI lives in the Playlist Files overlay (right hover edge).

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

### Global hotkeys

| Key | Action |
|-----|--------|
| `[space]` / `[arrow right]` | Next file in active playlist |
| `[arrow left]` | Previous file in active playlist |
| `[arrow up]` | Slide up the files selector and tag manager overlay |
| `[arrow down]` | Reveal / expand the audio player overlay (see Audio Player) |
| `[p]` | Pause all active playlists and show pause overlay |
| `[esc]` | Same as [p] in player mode, in paused or stopped state closes the window |
| `[delete]` | Move the active file of the active playlist to the system Trash |
| `[right option] + [arrow left]` | Video/Audio only — seek −3s |
| `[right option] + [arrow right]` | Video/Audio only — seek +3s |
| `[l]` | Loop current file indefinitely, until un-looped or manually navigated to next file, Video/Audio only |

When the audio player overlay is visible, the arrow keys control the **audio** playlist instead of the video/image playlist. Sequences like `[arrow down]` then `[arrow right]` therefore advance the audio playlist, not the video/image one.

### Pause overlay

Pressing `[p]` puts the active video/image playlist into **Paused** state and shows an opaque overlay on top of the media with two buttons:

- **Unpause** — resumes all playlists that were paused by this action. Note: if the audio playlist was already paused separately (via its own controls) before `[p]` was pressed, it stays paused.
- **Stop** — returns the video/image playlist to **Stopped** state (exits fullscreen Player mode, shows the playlist in Manager mode in the main window). The audio playlist has its own separate Stop control in the audio player; the main Stop button does not affect it.

Pressing `[p]` or `[space]` while paused unpauses, with the same caveat about separately-paused audio.

### Close and resume

`[esc]` in stopped/manager state closes the window, opening it again returns to stopped state.
`[esc]` in paused state closes the window. The app keeps running. Opening the window again restores the previously active playlists in their paused state, exactly as if `[p]` had been pressed before closing.

## Video player

The video player plays files from the active video playlist one after another.

Hover zones in fullscreen:

- **Top** — slides in the audio player overlay.
- **Left** — slides in the Playlists overlay for quick selection (plays-continues selected playlist right away)
- **Right** — slides in the Playlist Files and tag manager overlay for the active video playlist.
- **Bottom** — video play controls (previous, stop, next, loop. Track progress / scrub. Volume control).

Loop mode - Loop current file indefinitely, until un-looped or manually navigated to next file.

Video-specific hotkeys are listed under Playback Controls (3-second seeks).

## Image player

The image player shows the active file of the active image playlist.

### Fit modes

Images are presented in **fit** mode by default. The user can toggle between:

- **Fit** — fit the entire image inside the window, preserving aspect ratio (letterboxed where needed).
- **Cover** - shows clipped image to fill in the screen, preserving aspect ratio
- **Original** — show the image at 1:1 pixel size

There is no stretch / distort mode. A button in the image-player UI and a hotkey switch between these modes. Pan and zoom are supported in either mode using the trackpad / scroll wheel.

### Slideshow

When slideshow mode is on (by default it is off, configurable per playlist), the player advances to the next file after the configured interval. When off, the current image is shown indefinitely until the user advances manually.

Slideshow interval is configurable both globally and per playlist; the per-playlist value, when set, overrides the global default.

Hover zones are the same as for the video player.

## Audio player

Audio playlists use the same folder / shuffle / tag model as the other types but present themselves through a compact and extended overlay rather than fullscreen presentation.

States of the audio overlay:

1. **Hidden** (default) — nothing is shown for audio.
2. **Compact** — appears on hover over the top of the screen, or on first `[arrow down]`. Shows current track and basic controls.
3. **Extended** — second `[arrow down]` press expands the overlay to include the Playlists (filtered to audio playlists only), active playlist's Files and tag manager. Works as manager mode.
4. `[arrow up]` collapses the audio overlay back down toward hidden.

### Audio player controls

The compact / extended audio UI exposes typical player controls, similar to a standard music app:

- Play / pause (audio only — separate from the global `[p]` pause).
- Previous / next track.
- Stop (closes the current audio file; the audio playlist becomes idle without affecting the video/image playlist).
- Volume slider (per-playlist, persisted).
- Track progress / scrub.
Loop mode - Loop current file indefinitely, until un-looped or manually navigated to next file.

### Audio in parallel with video / image

When an audio playlist plays alongside a video, the audio is **mixed** with the video's own audio (the video is not muted). Each playlist keeps and persists its own volume level, so the user balances the mix once and the setting sticks for future sessions.


## Playlist Files overlay

Triggered by hovering over the right edge during video/image playback, or visible as part of the extended audio overlay.

Contents:

- The filter UI (tag multi-select + AND/OR switch, "Untagged" option, "Invalid tagging" option, saved multi-tag searches, frequently-used tags floated to the top). All filters here are specific to this playlist's own tags; there are no app-wide filters.
- The list of files in the active playlist, respecting the active filter.
- Skipped-files notice (count of unsupported files in the source folder).
- Invalid-tagging notice (count of files whose names contain more than one bracket group), with a one-click action to filter the list down to just those files for fixing.

Per-file actions:

- **Double-click** — jump the player to this file (starting from its remembered position).
- **Rename** the file on disk (the playlist updates in place).
- **Delete** the file (moves it to the system Trash and removes it from the playlist).
- **Show in Finder**.

Multi-select is supported (shift / command click). With a multi-selection, the user can delete all selected files at once, or edit tags across the whole selection — same semantics as in Manager mode (intersection of tags shown, additions/removals applied to every file in the selection).

If a file goes missing between when the playlist was built and when playback reaches it (deleted outside the app, moved, etc.), playback silently skips it and the file is removed from the playlist.

## Playlists overlay

Triggered by hovering over the left edge, or shown as the main-window content on the welcome screen when no players are active.

Contents:

- **Video** and **Image** playlists in separate sections (when summoned over a video/image session, or on the welcome screen).
- **Audio** playlists only, when summoned as part of the extended audio overlay.

When audio overlay is collapsed this playlists overlay will show collapsed "Audio" playlists section, pressing it will reveal extended audio overlay with it's own playlists control.

Per-playlist actions:

- Create a new playlist (opens folder picker).
- Rename.
- Delete (removes the playlist; files on disk are untouched).
- Reorder within its section.
- Select — makes this playlist the one shown in the main window (video / image) or the active audio playlist (audio). The playlist enters Stopped state; Play is a separate action.

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
- Volume (video/audio only)
- Filter state and saved searches.
- Frequently-used-tag ordering.
- Manager-mode file list view: list vs. gallery (video and image playlists only).

### App state persisted across launches

- Active video / image / audio playlists.
- Last-played file in each playlist.
- Last-played position within file, when enabled for that playlist.
- Whether playback is paused (so reopening after `[esc]` resumes the prior paused state).
- Window placement (best-effort, not really necessary because it will be either fullscreen or fully expanded).
