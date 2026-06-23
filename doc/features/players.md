> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Players (video, image, audio)

## Video player

The video player plays files from the Visual Channel Playlist one after another in fullscreen.

### Hover zones

- **Top edge** — slides in the Compact Audio Overlay (auto-closes when the cursor leaves; see [Audio player](#audio-player) for details).
- **Bottom-center** — the compact playback controls bar (reveal and dismissal behavior under Overlay interaction rules): previous, play/pause, stop, next, loop toggle, track progress / scrub, volume slider, and a **file list button** that toggles the Visual Overlay. Each control shows a hover highlight.

### Visual Overlay

Triggered by `[arrow up]`, `[tab]`, or the file list button in the bottom playback controls. Slides up from the bottom of the screen.

The overlay is a **simplified** view meant for quick playlist/file switching and single-file operations during playback — not the full management surface that Manager mode provides. It has three columns:

1. **Playlist selector** — the playlists of the active visual type (video *or* image), with a `+` to add one from a folder. Selecting a playlist switches the Visual Channel to it and starts playing it immediately. It does **not** expose full management (no rename, delete, or reorder — those live in Manager mode).
2. **File list & filtering** — the Filter Bar (tag multi-select, AND/OR switch, saved multi-tag searches — no Service Filter toggles, those live in Manager, though a Service Filter set there is honored here and its banner can clear it), the list of files in the Visual Channel Playlist (always list view, not gallery). If a filter change leaves nothing matching, the player stays in Player mode and shows a "No files match the filter" placeholder rather than dropping back to Manager.
3. **Tag management** — Tag Editor for the **current file** only (same UI as described in [Tag editing UI](tags.md#tag-editing-ui)).

Per-file actions in the list act on a single file:

- **Double-click** — play this file: the player switches to it, resumes if it was paused, and the overlay dismisses so playback continues unobstructed.
- **Rename** the file on disk (the playlist updates in place).
- **Delete** the file (moves it to the system Trash and removes it from the playlist).
- **Show in Finder**.

Bulk operations — multi-select delete and editing tags across a selection — are reserved for Manager mode; the overlay focuses on the current file for fast in-playback edits.

If a file goes missing between when the playlist was built and when playback reaches it, playback silently skips it and the file is removed from the playlist.

## Image player

The image player shows the current file of the Visual Channel Playlist in fullscreen.

### Fit modes

Images are presented in **Fit** mode by default. The user can cycle through modes with `[shift]`:

- **Fit** — fit the entire image inside the window, preserving aspect ratio (letterboxed where needed).
- **Cover** — shows clipped image to fill the screen, preserving aspect ratio.
- **Original** — show the image at 1:1 pixel size.

There is no stretch / distort mode. Pan and zoom are supported in **Original** mode using the trackpad / scroll wheel.

### Slideshow

When slideshow mode is on (by default it is off, configurable per playlist), the player advances to the next file after the configured interval. When off, the current image is shown indefinitely until the user advances manually.

Slideshow interval is configurable both globally (default 10s) and per playlist; the per-playlist value, when set, overrides the global default.

### Hover zones

- **Top edge** — slides in the Compact Audio Overlay (same behavior as video player).
- **Bottom-center** — a compact playback controls bar (same hover-to-reveal behavior as the video player): previous, stop, next, slideshow on/off toggle, slideshow interval selector, and a **file list button** that toggles the Visual Overlay. A play/pause button appears only while a slideshow is running (a still image has nothing to pause).

The Visual Overlay works identically to the video player's (see above).

## Audio player

Audio playlists use the same folder / shuffle / tag model as the other types. They are first-class **Manager** content (the audio Scope, see [Manager mode](manager-mode.md)) and play through the parallel Audio Channel that never enters fullscreen independently. The Audio Channel is controlled from its two surfaces — the Audio Inlet and the Audio Overlay — detailed below.

### Audio Inlet (Manager mode)

- **No Audio Channel Playlist is active** — a music glyph and a **Play** that cascades: with no audio playlists, it opens the add-folder flow; with some, it starts the first one.
- **An Audio Channel Playlist is active** — the state-dependent transport (below). The track name and a thin track-progress bar appear only once a current track is available; an active playlist with no current file yet shows just the transport.

### Audio Overlay (Player mode)

A single overlay with a compact and an expanded state:

1. **Hidden** (default) — nothing is shown for audio.
2. **Compact** — a slim top bar with the current track and the transport (plus track progress / scrub and a volume control). Appears via:
   - **Hovering** over the top edge of the screen — auto-closes when the cursor leaves the overlay area.
   - **`[arrow down]`** from Hidden — stays open until explicitly closed. Does not auto-close on mouse leave; closes on click outside or `[arrow up]`.
3. **Expanded** — the same bar with a lower section revealed: an audio playlists **selector** (with a `+` to add one — selecting a playlist plays it immediately), the Audio Channel Playlist's file list with filtering, and tag management for the current track. Playlist rename / delete / reorder live in the Manager. It does not pause playback (TBD, maybe it should in the same way the Visual Overlay does, to prevent jumping to another track while the Tag Editor is engaged).

### Navigation between overlay states

- `[arrow down]` and `[arrow up]` step between the overlay states; see [Player mode hotkeys](playback-controls.md#player-mode-hotkeys) for the exact transitions and how they depend on Key Context.
- A chevron on the compact bar expands and collapses the lower section; a close button dismisses the overlay.

In the **Expanded** state the file list is a simple vertical list, so it does not need left/right arrows for its own navigation: while audio holds Key Context, `[arrow left]` / `[arrow right]` still switch to the previous / next audio track, and `[arrow up]` progressively closes the overlay. Arrow keys therefore do not move a selection within the Expanded file list (a future revision may add focusable, `[tab]`-navigable zones). The exception is when a text field inside the overlay is in edit mode (e.g. inline rename), where the standard text-editing keys apply — move the cursor, delete the character to the left, delete the selection, and so on.

### Audio controls

The Audio Transport — shared by the Audio Inlet and the Audio Overlay — renders only the controls actionable in the current state (no dead buttons): **Stopped** shows Play · Volume; **Playing** shows Previous · Pause · Stop · Next · Loop · Volume; **Paused** shows Previous · Play(unpause) · Stop · Next · Loop · Volume. Across both surfaces it exposes:

- Play / pause (audio only — sets the Audio Channel Playlist's per-playlist paused state; separate from `[p]` Suppression).
- Previous / next track.
- Stop (returns the Audio Channel Playlist to Stopped state without affecting the Visual Channel Playlist).
- Volume slider (per-playlist, persisted).
- Track progress / scrub.
- Loop toggle — loop current file indefinitely, until un-looped or manually navigated to next file.

### Audio in parallel with video / image

When an Audio Channel Playlist plays alongside a video, the audio is **mixed** with the video's own audio (the video is not muted). Each playlist keeps and persists its own volume level (relative to system volume level), so the user balances the mix once and the setting sticks for future sessions.
