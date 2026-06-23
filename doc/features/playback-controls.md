> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Playback controls

## Esc behavior

`[esc]` has context-dependent behavior, evaluated in this priority order:

0. **A trash confirmation is open** (the Player `[delete]` dialog or the Manager delete dialog) → cancels it. `[enter]` confirms it. While it is open it holds Key Context: every other key is ignored, so nothing rings the system bell.
1. **Tag input is focused** → unfocuses the tag input. No other effect.
2. **An overlay is open** (Visual Overlay, Audio Overlay opened by hotkey) → closes the topmost overlay. Playback continues.
3. **Playing (no overlays open)** → activates Suppression and shows the Pause Overlay. The window stays open.
4. **Suppressed (Pause Overlay shown, no other overlays)** → closes the window. The app keeps running. Suppression stays active while the window is closed; opening the window again lifts it, and Playing playlists continue.
5. **Stopped / Manager mode** → if in the middle of some operation (renaming, dialog, tagging) - cancels operation, otherwise has no effect (the window stays open).

The bottom playback controls bar and the Pause Overlay are not considered "overlays" for Esc purposes — the bar dismisses itself when the cursor leaves, and the Pause Overlay is governed by rules 3–4 (pressing `[esc]` while it is shown closes the window).

## Player mode hotkeys

These hotkeys apply during video or image playback (Playing or Paused state). When a text input (e.g. Tag Editor, filter search) is focused, all keys are captured by the input and do not trigger player actions.

**Key Context.** Arrow keys, `[space]`, `[l]`, and seek are routed to whichever target currently holds *Key Context*:

- By default the Visual Channel holds Key Context.
- When the Audio Overlay is revealed (Compact or Expanded) it takes Key Context, but only once it is **fully** revealed (after the slide-in animation completes). This applies whether the Audio Overlay was opened by hotkey or by hover. Closing the Audio Overlay back to Hidden returns Key Context to the Visual Channel.

While the Visual Channel holds Key Context:

| Key | Action |
|-----|--------|
| `[space]` | Lift Suppression when the Pause Overlay is active (leaving each playlist's own pause state untouched). Otherwise pause / unpause the Visual Channel Playlist. |
| `[arrow right]` | Next file in the Visual Channel Playlist |
| `[arrow left]` | Previous file in the Visual Channel Playlist |
| `[tab]` | Toggle the Visual Overlay: opens it when closed, closes it when open (however it was opened). |
| `[arrow up]` | Open the Visual Overlay if it is closed. If it is already open, no effect (use `[tab]`, `[arrow down]`, or `[esc]` to close it). |
| `[arrow down]` | If the Visual Overlay is open: close it. Otherwise: reveal the Audio Overlay (Hidden → Compact). |
| `[p]` | Activate Suppression and show the Pause Overlay (halts all playback, including audio) |
| `[s]` | Stop the Visual Channel Playlist and return to Manager mode |
| `[esc]` | Close overlay → suppress (if playing) → close window (if suppressed). See Esc behavior above. |
| `[delete]` | Ask to move the current file to the system Trash (a confirmation dialog appears; see below) |
| `[shift]` | Cycle image fit modes: Fit → Cover → Original (image playlists only) |
| `[l]` | Toggle loop on the current file (video only here) |
| `[right option] + [arrow left]` | Seek −3 s (video only here) |
| `[right option] + [arrow right]` | Seek +3 s (video only here) |

The `[delete]` confirmation dialog **holds Key Context until it closes**: `[enter]` confirms (trashes the file and advances to the next still-available file), `[esc]` cancels, and all other keys are ignored while it is shown. After a delete, if the playing file was the one removed, playback advances to the next remaining file.

**When the Audio Overlay holds Key Context** (revealed as Compact or Expanded), arrow keys, `[space]`, `[l]`, and seek act on the Audio Channel Playlist instead:

| Key | Action (Audio Overlay has Key Context) |
|-----|--------|
| `[arrow left]` | Previous track in the Audio Channel Playlist |
| `[arrow right]` | Next track in the Audio Channel Playlist |
| `[space]` | Lift Suppression when the Pause Overlay is active (leaving each playlist's own pause state untouched). Otherwise pause / unpause the Audio Channel Playlist. |
| `[arrow up]` | Close the Audio Overlay to Hidden (from either Compact or Expanded). A Visual Overlay that is also open stays open; Key Context returns to the Visual Channel. |
| `[arrow down]` | Step the Audio Overlay Compact → Expanded. (Expanded is exclusive and closes the Visual Overlay.) |
| `[l]` | Toggle loop on the current audio track |
| `[right option] + [arrow left/right]` | Seek the audio track ∓3 s |

## Manager mode hotkeys

In Manager mode (Stopped state), most playback hotkeys are inactive. The following apply:

| Key | Action |
|-----|--------|
| `[arrow up]` / `[arrow down]` | Move the file selection. In the list this steps one row; in the gallery it steps a full row up/down. Collapses any multi-selection to a single item and scrolls it into view. |
| `[arrow left]` / `[arrow right]` | In the gallery, step the selection one cell left/right. In the list there is no horizontal axis (the keys are consumed without effect). |
| `[enter]` | Play the selected file (enters Player mode starting from it), the keyboard equivalent of double-clicking it. Inactive while a text field (rename, tag input) is focused, where `[enter]` commits that field instead. With nothing selected the key passes through. |
| `[esc]` | Cancel an in-progress operation (rename, dialog, tagging); otherwise no effect — the window stays open (see Esc behavior, rule 5). |
| `[delete]` | Ask to move selected file(s) to the system Trash (a confirmation dialog appears) |

Arrow keys are consumed by the file-list/gallery navigation, so they never ring the system beep. The Manager delete confirmation holds Key Context: `[enter]` confirms, `[esc]` cancels, and other keys are ignored while it is shown.

Audio Channel playback control by keyboard is a Player-mode concern (see Key Context above).

## Overlay interaction rules

Overlays in Player mode follow exclusivity and dismissal rules:

- **Visual Overlay** — while open, the bottom playback controls' hover trigger is suppressed. Compact audio can still appear on top (via top-edge hover); while compact audio is presented, `[arrow down]` both expands audio to its lower section and closes the Visual Overlay. **While the Visual Overlay is open, the Visual Channel Playlist's playback/slideshow is paused** so it cannot advance to the next file while tags are being edited; it resumes when the overlay closes (a playlist the user had paused stays paused).
- **Expanded Audio Overlay** — exclusive with all other overlays. Opening it closes the Visual Overlay. All hover triggers are suppressed while it is shown.
- **Compact Audio Overlay** — closes automatically when any other hotkey-triggered overlay opens (the Visual Overlay via `[arrow up]`/`[tab]`).
- **Bottom playback controls** — compact and bottom-centered. They live in place but stay transparent until the cursor hovers their footprint, then fade in; they fade out and auto-dismiss when the cursor leaves. They never persist across a stop/start, and are hidden while the Visual Overlay is open or while suppressed. There is no on-screen "Back to Manager" button — leave Player mode with `[s]`, the Pause Overlay's **Stop**, or `[esc]`.

## Pause Overlay

Pressing `[p]` (or `[esc]` while playing) activates Suppression and shows an opaque overlay on top of the media with two buttons:

- **Unpause** — ends the Suppression; every playlist in Playing state continues, while playlists in their own Paused state stay paused.
- **Stop** — returns the Visual Channel Playlist to **Stopped** state (exits fullscreen Player mode, shows the playlist in Manager mode in the main window). The Audio Channel Playlist has its own separate Stop control; the main Stop button does not affect it.

Pressing `[p]` or `[space]` while the Pause Overlay is shown also ends the Suppression.

### Suppression vs per-playlist pause

Each playlist is always Stopped, Playing, or Paused - a persistent per-playlist state. **Suppression** is a single transient layer on top of those states: actual playback happens only while a playlist is Playing and Suppression is off (`playback = playing && !suppression`).

Suppression is active while the Pause Overlay is shown or the window is closed; when it ends (Unpause, or reopening the window), every Playing playlist continues. Quitting and relaunching the app behaves the same way as closing and reopening the window. Since the Pause Overlay hides the whole UI, playback controls only ever reflect the playlist states.

**Per-playlist paused state** is set via the play/pause control in a playlist's own playback controls (video/image bottom bar, Audio Overlay). It persists through Suppression, window closing, and quitting/restarting. It is cleared when another playlist of the same kind is made active (video and image playlists also clear each other this way).
