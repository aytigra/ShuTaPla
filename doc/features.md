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

- **Video**: mp4 and webm (including VP9) primarily. Other common formats accepted opportunistically. HDR supported where the OS and display allow.
- **Image**: jpeg, png, jpeg xl, gif, and other common formats. HDR supported where available.
- **Audio**: mp3 primarily, plus other common formats.

Unsupported files in a selected folder are ignored silently. A small, non-intrusive notice in the playlist info area surfaces the count of skipped files so the user knows they exist without cluttering the main UI. Clicking the notice activates the Skipped service filter (see Filtering and search), which lists the skipped files for inspection — they can be shown in Finder or trashed, but never play.

### Cloud / offline files

Source folders may live in cloud storage (for example an iCloud Drive folder) where files are not always downloaded locally. The app surfaces this state per file:

- An **"in the cloud"** indicator marks files that are not yet downloaded (placeholder / evicted).
- A **"downloading from cloud"** indicator marks files that are actively being fetched.

These indicators appear in every file list (Manager list and gallery, and the Files & Tags overlay). To avoid stalls, the app **prefetches ahead**: while the current file plays, it requests the download of the next files in line (default: the next 3) so they are ready by the time playback reaches them. If a file is still in the cloud when playback reaches it, the app requests its download immediately and shows the downloading indicator; if it cannot be made available in time, playback advances to the next available file (unless the file was selected explicitly by double-click from a file list — in that case playback waits for the download to finish).

## First launch and creating playlists

On first launch, the main window shows a welcome state with a prominent button to add the first playlist.

A playlist can be created in three equivalent ways:

1. Welcome-state button.
2. The New Playlist (`+`) button in the Manager toolbar.
3. The application menu.

Each path opens a folder picker. Once the new playlist's media type is known, the Manager switches to the matching scope (image, video, or audio) and loads the new playlist as the managed one, **Stopped** — these paths create it for management without starting playback (an audio creation, like an audio selection, first stops whichever audio playlist was live). The player-mode overlays add a fourth and fifth entry point through the `+` in their playlist selectors; there, consistent with selecting in those overlays, the new playlist **starts playing** immediately on its channel, and the Manager scope is left unchanged — so stopping back into Manager returns to whatever was being managed rather than dropping into the new playlist's scope.

When a folder is read, the app classifies its contents by media type. A folder is **dominant** in one type when the other types are only an incidental minority (for example, a handful of album-cover images among many audio tracks) — concretely, when at least 80% of the recognized media files are of that type:

- All-video or video-dominant → video playlist.
- All-image or image-dominant → image playlist.
- All-audio or audio-dominant → audio playlist.
- **Mixed** — any folder without a clearly dominant type → the app prompts the user to choose which media type this playlist should be. Files of the other types in that folder are then treated as unsupported for this playlist. The prompt is also the safety net whenever the classification is not obvious.

A single folder may back multiple playlists (for instance, an audio playlist and an image playlist over the same folder).

If the selected folder contains no supported media files at all, the app shows a brief message and does not create a playlist.

Scanning a large folder can take a moment. The new playlist appears in the Playlists panel immediately with a progress spinner and fills in once the scan completes, so adding a folder never leaves the window looking idle.

## Playlists

Each playlist stores:

- Its origin folder path.
- The full list of files found recursively at creation time, in shuffled order.
- A display name (defaults to the folder name, can be renamed).
- Its own preferences: volume (relative to system volume, default 100%), slideshow interval, slideshow enabled, file-position persistence, image fit mode, list/gallery mode.
- Its state: active state, current file, playing/paused, file-position, filter state, search history, frequently-used-tag ordering (see relevant sections below).

### Global settings

- Default slideshow interval (initially 10 s).
- Default file-position persistence behavior (whether playlists resume mid-file by default; initially off).
- Default image fit mode (initially Fit).

### Reshuffle vs. Update

Each playlist refreshes from disk two ways:

- **Reshuffle** — a toolbar button that re-reads the folder and rebuilds the file list from scratch with a new random order. Last-played position is reset.
- **Update** — re-reads the folder, appends any newly discovered files at the end, and prunes files that have disappeared from disk. Ordering and last-played position are preserved. It runs automatically whenever a playlist becomes active — including re-selecting the open playlist — so new files appear without a dedicated control.

All folder re-reads (Reshuffle and the automatic Update) run in the **background** without blocking the UI, with a small "sync in progress" indicator shown while a re-read is running.

### Playback order and wrap-around

Files play in the playlist's stored shuffled order. Advancing past the last file wraps around to the first and playback continues — the order is not reshuffled. Stepping to the previous file from the first file wraps to the last. When a filter is active, wrap-around applies to the filtered sequence.

### Playlist states

A playlist is always in one of three states:

- **Stopped (Manager mode)** — the default state when a playlist is selected but not playing. The main window shows the playlist's contents in Manager mode (see next section). The "active file" (last-played, or first if none) is highlighted but not playing.
- **Playing** — the playlist's files are being presented one after another. Video and image playlists enter **fullscreen** Player mode. An audio playlist plays through the parallel audio channel without changing the main window — it stays controllable from the Manager's audio inlet, and from the player-mode audio overlay during video/image playback (see Audio Player).
- **Paused** — playback is halted.

### Transitions between states

- **Selecting** a visual playlist in Manager mode (from the left playlists panel) puts it in **Stopped** state and shows it in the Manager view. **Selecting an audio playlist** in Manager mode makes it the active, **Stopped** audio playlist; because only one audio playlist is ever live, this first stops whichever audio playlist was playing.
- **Selecting** a playlist from the Files & Tags overlay's selector during Player mode immediately starts **Playing** the selected playlist. Likewise, selecting an audio playlist from the player-mode audio overlay starts it playing.
- **Play** (the visual toolbar's Play button, or the audio inlet's / overlay's Play control) transitions to **Playing**. Playback resumes from the playlist's last-played or first file. If file-position persistence is enabled for the playlist, playback also resumes from the last position within that file; otherwise it starts from the beginning of the file.
- **Double-clicking a file** in the file list (whether in Manager mode or in the Files & Tags overlay during play) transitions to **Playing** starting from that file (always from the start).
- **`[p]`** activates suppression (see Suppression vs per-playlist pause); playlist states are unchanged.
- **Stop button** (in the pause overlay, or in the playback controls) transitions back to **Stopped** — the playlist returns to its Manager view.
- **`[esc]`** — context-dependent (see Esc behavior under Playback Controls).

### Concurrent playlists

At any time:

- At most one video playlist OR one image playlist may be in **Playing** or **Paused** state.
- At most one audio playlist may be in **Playing** or **Paused** state in parallel with the above.
- Any number of playlists may exist in **Stopped** state. The Manager view shows one **scope** at a time — image, video, or audio — and manages one playlist's contents. Switching the Manager between scopes, or to a different playlist, is a view change only: it never interrupts an audio playlist that is currently Playing in parallel (and vice versa).

Switching to a different visual playlist (within or between video and image) cleanly stops the previous one (it returns to Stopped state) and brings the new one up. In Manager mode the new playlist does **not** auto-start; it appears in its Manager view. In Player mode (via the Files & Tags overlay's playlist selector) the selected playlist starts playing immediately. Selecting a different **audio** playlist in Manager mode stops whichever audio playlist was live and leaves the new one active and Stopped (selecting from the player-mode audio overlay starts it playing instead). Each playlist's last-played file and optional position-within-file are preserved, so returning to it later resumes where it was.

## Manager mode

Manager mode is the main-window view of a playlist when it is in the Stopped state. It is also the view the user returns to after pressing Stop.

In Manager mode the window content is laid out as panels — no overlays are used. The independent audio channel is controlled inline from the audio inlet at the top of the left panel rather than through an overlay.

### Scopes

The Manager manages **one playlist at a time** — the managed playlist — and the whole view (sidebar, center file list, filter bar, tag inspector) binds to it, adapting to its type. **Scope** is only the sidebar's playlist-list type filter: three **scope tabs** in the toolbar — **Image**, **Video**, **Audio** — choose which type of playlist you can pick from to become the managed one. It is not selection, filter, or routing state.

| Scope | Sidebar shows |
|---|---|
| **Image** | Image playlists |
| **Video** | Video playlists |
| **Audio** | Audio playlists |

Switching scope is the browse gesture: it never starts or stops any channel, and pre-loads that scope's last-managed playlist into the managed slot (so switching to a type you haven't browsed shows the placeholder). Each playlist carries its own persisted filter, service filter, and current file, so those follow the playlist rather than the scope; the selection belongs to the managed playlist. Audio is first-class Manager content — it reuses the same sidebar / center / filter / tag machinery as the visual types, minus the gallery view. The scope is persisted, as is each visual type's last-managed playlist, so Manager reopens to where you left it (defaulting to video).

### Layout

- **Toolbar** — replaces a window-title strip. Left: the scope tabs and the New Playlist (`+`) button (which opens the add-folder flow, then switches to the created playlist's scope and loads it as the managed one). Center: the managed playlist's name as the window title (placeholder "\(app_name)" when nothing is loaded), and its type's actions — image/video: Play · Reshuffle · List/Gallery toggle · Settings; audio: Reshuffle · Settings. Right: the tag controls (Manage Tags, the tag-inspector toggle). Clicking the *active* scope tab collapses the left panel; clicking any tab while collapsed expands it and sets that scope. Image/video **Play** enters fullscreen Player mode; audio has no toolbar Play (audio playback starts from the inlet and stays in Manager).
- **Left collapsible panel** — pinned at the top, the **audio transport inlet** (present in every scope, since the audio channel is parallel to whatever is being browsed; see Audio Player). Below it, the active scope's **playlist list** with full management (create via the toolbar's New Playlist, inline rename, delete, drag reorder). A playlist with a background re-scan in progress shows a spinner in place of its file count; deleting a large playlist clears the selection at once and the row shows a red progress spinner while its files are cleaned out in the background, staying visible until removal completes.
- **Center** — filtering controls (tag multi-select, AND/OR switch, saved multi-tag searches), counter notices for untagged / invalid tagging / skipped files (each activates its service filter — see Service filters), and the file list respecting the active filter. Serves the managed playlist.
- **Right collapsible panel** — Tag management, shown in one of two modes selected from a toolbar button next to the panel's show/hide control. The default mode edits the tags of the file(s) currently selected in the center list (the same multi-select tag input described under Tag editing UI); its heading reflects the selection — **File Tags** for a single file, **Common Tags** for a multi-selection. The toolbar button switches the panel into **Manage Tags** mode (see Playlist-wide tag operations) and back; entering it reveals the panel if it was hidden. It edits the managed playlist.

### File list view modes

For video and image playlists, the file list can be shown as:

- **List** (default).
- **Gallery** with thumbnails.

The choice is persisted per playlist. Audio playlists always use list view.

For video and audio playlists, each file shows its running time: a right-aligned column in the list (after the tag chips, which keep a common right edge), and for video also a badge in the bottom-right corner of the gallery thumbnail. The length is read on first display and cached, so it appears instantly on later displays and across launches. Images have no timeline and show no length.

### File interactions

- **Click** — select a file (also focuses it for the tag panel).
- **Double-click** — enters Player mode starting from that file (always from beginning of that file, resets file-position).
- **Multi-select** — standard shift / command click to select multiple files at once. With a multi-selection:
  - **Delete** moves all selected files to the system Trash and removes them from the playlist.
  - **Tag edits in the right panel** apply to all selected files. The chips shown represent the **intersection** of tags across the selection (tags every selected file has). Adding a tag adds it to every selected file (a no-op for files that already have it); removing a chip removes that tag from every selected file.
- **Rename** an individual file is also available as a per-file action (context menu / inline rename).
- **Show in Finder** is available per file.
- **Remove Audio** (video playlists only) strips the audio track from the file — or from the whole selection when invoked on one of several selected files. It is confirmed with the same `[enter]`/`[esc]` dialog as Delete. The video stream is copied, not re-encoded, so it is fast and lossless and works for every container the player can open (including webm/mkv). The original is moved to the Trash as a recoverable backup and the audio-free file takes its place; a file currently on screen is reloaded and resumed at its position. The work runs in the background, with a spinner on each file's row while it processes.

### Playlist-wide tag operations

In addition to per-file and per-selection tag editing, Manager mode exposes operations that act on **every file in the playlist** — letting tags be curated without selecting or opening any file. The right panel's **Manage Tags** mode lists every tag in the playlist with its file count; each row offers:

- **Rename a tag** across all files that have it — inline editing in a field that takes focus immediately, confirmed with `[enter]` and cancelled with `[esc]`. Renaming onto a tag that already exists is refused with a message rather than silently merging the two.
- **Remove a tag** from all files that have it. Because this renames files on disk and can't be undone, it asks for confirmation first.

Both operations rename the underlying files on disk to match. When removing the last tag would leave a file with an empty name (a name that is only its bracket group), the file is renamed to a placeholder base instead of an empty/hidden name.

## Tag system

Tags are not a separate entity tracked by the app — they are literally what appears inside `[...]` in a filename. Reading tags means parsing filenames; editing tags means renaming files.

### Tag syntax in filenames

Tags live inside a single square-bracket group in the filename, e.g. `holiday clip [beach summer family].mp4`.

Rules:

- Exactly one bracket group per file. Files containing more than one bracket group are considered to have **invalid tagging** (see below) — they are not treated as untagged.
- The bracket group may appear anywhere in the filename, not only at the end.
- Tags inside the brackets are separated by spaces.
- Allowed characters per tag: letters, digits, and underscore.
- Minimum tag length: 3 characters.
- A single bracket group is valid tagging only when **every** space-separated token inside it is a valid tag (allowed characters and length). If **any** token fails, nothing is silently ignored — the file is flagged as **invalid tagging** (see below).
- An **empty** bracket group (`[]`, or whitespace only) yields no tags; the file is treated as **untagged**, and the empty group is cleaned up the next time the file's tags are edited.
- A non-empty bracket group containing **any** token that fails the rules above (for example `[beach ab]`, where `ab` is too short, or `[a b c]`) is **not** treated as untagged. It is flagged as **invalid tagging** (see below) so its contents are surfaced to the user and never silently dropped on the next tag edit.
- Tags are **case-insensitive**. They are normalized for matching and filtering but the on-disk casing is preserved when reading and writing.
- Duplicate tags never accumulate: adding a tag a file already has (case-insensitively) is a no-op, and a playlist-wide tag rename that would produce a duplicate within a file collapses it to a single instance.
- A file without any bracket group is **untagged**. Untagged files are surfaced via a counter notice that activates the Untagged service filter.
- Removing the last tag from a file also removes the now-empty brackets from the filename.

### Invalid tagging

A file is considered to have invalid tagging when its bracket usage is either ambiguous or would lose information:

- **More than one bracket pair**, or **nested brackets** (which also break the single-pair rule) — the app cannot decide which group holds the tags.
- A single bracket group containing **any** token that is not a valid tag (for example `[beach ab]` or `[a b c]`). Flagging it as invalid keeps that content from being silently discarded on the next tag edit. 

A single stray, unmatched bracket that does not break parsing (for example a literal `[` or `]` used in prose) is simply ignored, not treated as invalid. These invalid files are not silently ignored:

- The playlist surfaces a counter notice showing the count of files with invalid tagging; clicking it activates the Invalid tagging service filter.
- While that filter is active, the list shows only those files, so the user can step through them and fix each one with a simple rename.
- Until fixed, an invalid-tagged file still plays normally as part of the playlist; it simply does not contribute any tags and is excluded from any tag-based filter (it appears under the Invalid tagging service filter).

### Tag cache

When a playlist is created (and after each Update / Reshuffle) the app collects all tags from all filenames in the playlist and caches them as the playlist's known-tags set. This drives the dropdown suggestions in the tag editor and the filter UI. Adding new tags to files also adds them to the tag cache so they appear in suggestions. Remove/rename tag playlist-wide operations also rename/remove them in the cache.

### Tag editing UI

The tag editor is used in three places: the right panel in Manager mode (serving whichever scope is active), the tag section of the Files & Tags overlay in Player mode, and the player-mode audio overlay. In all cases the UI and behavior are identical.

The tag editor applies to the **currently selected or active file(s)**. UI is a multi-select tag input:

- Existing tags appear as chips.
- A text input lets the user type freely. As they type, a dropdown shows matching existing tags and commonly used tags from the playlist's cache.

When the selected or active file has **invalid tagging**, the chip editor is not shown — editing by chip would rewrite the filename and risk dropping the bracket content (which could be relevant). Instead the editor displays an **"invalid tag syntax"** message that explains the problem and offers a plain filename-rename field so the user can fix the name by hand. Once the filename parses cleanly (valid or untagged), the chip editor returns automatically. In a Manager multi-selection, files with invalid tagging are excluded from tag add/remove operations and called out so the user can fix them individually.

### Tag input hotkeys

The input does not take focus on its own — clicking the field opens it for editing; clicking outside it (or `[esc]`) gives focus up. While it is focused, all keys are captured by the tag editor and do not trigger player or overlay actions.

| Key | Action |
|-----|--------|
| `[arrow left]` / `[arrow right]` | Move the selection one chip left / right (with the input empty) |
| double `[arrow left]` / `[arrow right]` | Jump the selection to the first / last chip |
| `[arrow up]` / `[arrow down]` | Move through the dropdown suggestions |
| `[delete]` | Remove the selected tag chip (or, with none selected, the last one) |
| `[enter]` | Confirm the highlighted dropdown option, or add the typed string as a new tag |
| `[esc]` | Unfocus the tag input (does not close the overlay or pause) |

Adding, removing, or renaming a tag immediately renames the underlying file on disk. The playlist's reference is updated in place so play position is not lost.

If the app has lost write access to a playlist's folder (the saved permission went stale, or the folder moved or was renamed), it asks the user to locate the folder again before the edit; once re-granted, it remembers the new permission and proceeds. If a disk operation still fails — a rename that would collide with an existing filename, a permission error, a read-only or disconnected volume, or any move-to-Trash failure — the app does not lose the file or its playlist entry: it leaves the file as-is and surfaces a clear, non-blocking notification so the user knows to resolve it. This applies to all file mutations (tag edits, renames, deletes, and playlist-wide tag operations).

## Filtering and search

The filter UI appears in the inspector (right) panel of Manager mode (targeting the managed playlist), in the Files & Tags overlay during Player mode, and in the player-mode audio overlay. Each surface points its filter bar at one playlist's persisted filter; editing it from any surface edits the one stored filter, and every view that shows that playlist re-derives.

### Current scope

For the first version, each playlist's filter is a single flat multi-select of tags plus an **AND / OR** switch that applies to the whole selection. The filter is **per playlist** — not a single app-wide setting — so each playlist's current combination of selected tags and AND/OR mode is its own.

Tags are picked with the same multiselect-autocomplete control as the tag editor — selected tags as chips, a typed-into dropdown of matching tags — but in search-only mode: it adds existing tags to the filter and cannot create new ones.

### Service filters

Separate from the tag filter, the playlist carries one of three **service filters**: **Untagged**, **Invalid tagging**, and **Skipped**. Each surfaces as a small counter notice in the Manager center's playlist info area (shown only when its count is non-zero); clicking the notice activates the corresponding service filter, and clicking it again deactivates it. While a service filter is active, the file list shows only its files and the tag filter is temporarily inactive; service filters are mutually exclusive with each other.

- **Untagged** — files without any bracket group.
- **Invalid tagging** — files with invalid tagging (see Invalid tagging), for stepping through and fixing them.
- **Skipped** — files found in the folder but excluded from the playlist as unsupported or of another media type; listed for inspection only (Show in Finder, move to Trash) and never play.

Like the tag filter, an active Untagged or Invalid tagging service filter affects playback — only matching files play; Skipped files never play, so the playable sequence under the Skipped filter is empty (looping it would have nothing to show). Because of that, while a playlist's active filter is Skipped the Manager Play button is hidden and the audio inlet's Play is a no-op.

The service filter is persisted on the playlist, alongside the tag filter, and applied uniformly — Manager, the overlays, and playback all honor it — so triaging the untagged or invalid-tagged set resumes across launches. The counter-notice **toggles** that set it live only in the Manager center; the Files & Tags overlay and the player-mode audio overlay carry no service-filter toggles, but they still honor a service filter set in Manager (and show its "Showing untagged — clear" banner, which clears it).

Filtering affects playback: files that don't match are silently skipped during play (in addition to being hidden from the file list). Whenever the active file becomes unavailable for any reason — it is deleted, goes missing on disk, or is excluded by the current filter — playback advances to the next available file.

### Filter persistence and history

- Each playlist remembers its current filter selection across playlist switches, so returning to a playlist restores its filter.
- **Search history** is playlist-scoped and split into two parts:
  - **Multi-tag searches** (two or more tags in either AND or OR mode) are remembered as saved searches, listed for quick re-selection. A saved search captures **both its tag set and its AND/OR operator**; selecting it restores that exact combination. The list keeps the 10 most recent unique searches — re-applying an already-saved combination moves it to the top instead of adding a duplicate; an entry can be removed manually.
  - **Single-tag filters** are not stored as separate entries; instead, frequently used tags float to the top of the autocomplete dropdown within that playlist.

### Future direction (not in scope yet)

Per-search AND/OR toggling and grouped expressions (e.g. `A AND B AND (C OR D)`) are intended but not part of the initial version.

## Playback controls

### Esc behavior

`[esc]` has context-dependent behavior, evaluated in this priority order:

0. **A trash confirmation is open** (the Player `[delete]` dialog or the Manager delete dialog) → cancels it. `[enter]` confirms it. While it is open it holds key context: every other key is ignored, so nothing rings the system bell.
1. **Tag input is focused** → unfocuses the tag input. No other effect.
2. **An overlay is open** (Files & Tags overlay, audio overlay opened by hotkey) → closes the topmost overlay. Playback continues.
3. **Playing (no overlays open)** → activates suppression and shows the pause overlay. The window stays open.
4. **Suppressed (pause overlay shown, no other overlays)** → closes the window. The app keeps running. Suppression stays active while the window is closed; opening the window again lifts it, and Playing playlists continue.
5. **Stopped / Manager mode** → if in the middle of some operation (renaming, dialog, tagging) - cancels operation, otherwise has no effect (the window stays open).

The bottom playback controls bar and the pause overlay are not considered "overlays" for Esc purposes — the bar dismisses itself when the cursor leaves, and the pause overlay is governed by rules 3–4 (pressing `[esc]` while it is shown closes the window).

### Player mode hotkeys

These hotkeys apply during video or image playback (Playing or Paused state). When a text input (e.g. tag editor, filter search) is focused, all keys are captured by the input and do not trigger player actions.

**Key context.** Arrow keys, `[space]`, `[l]`, and seek are routed to whichever target currently holds *key context*:

- By default the active video/image player holds key context.
- When the audio overlay is revealed (Compact or Expanded) it takes key context, but only once it is **fully** revealed (after the slide-in animation completes). This applies whether the audio overlay was opened by hotkey or by hover. Closing the audio overlay back to Hidden returns key context to the player.

While the player holds key context:

| Key | Action |
|-----|--------|
| `[space]` | Lift suppression when the pause overlay is active (leaving each playlist's own pause state untouched). Otherwise pause / unpause the active playlist. |
| `[arrow right]` | Next file in active playlist |
| `[arrow left]` | Previous file in active playlist |
| `[tab]` | Toggle the Files & Tags overlay: opens it when closed, closes it when open (however it was opened). |
| `[arrow up]` | Open the Files & Tags overlay if it is closed. If it is already open, no effect (use `[tab]`, `[arrow down]`, or `[esc]` to close it). |
| `[arrow down]` | If the Files & Tags overlay is open: close it. Otherwise: reveal the audio overlay (Hidden → Compact). |
| `[p]` | Activate suppression and show the pause overlay (halts all playback, including audio) |
| `[s]` | Stop the visual playlist and return to Manager mode |
| `[esc]` | Close overlay → suppress (if playing) → close window (if suppressed). See Esc behavior above. |
| `[delete]` | Ask to move the active file to the system Trash (a confirmation dialog appears; see below) |
| `[shift]` | Cycle image fit modes: Fit → Cover → Original (image playlists only) |
| `[l]` | Toggle loop on the current file (video only here) |
| `[right option] + [arrow left]` | Seek −3 s (video only here) |
| `[right option] + [arrow right]` | Seek +3 s (video only here) |

The `[delete]` confirmation dialog **holds key context until it closes**: `[enter]` confirms (trashes the file and advances to the next still-available file), `[esc]` cancels, and all other keys are ignored while it is shown. After a delete, if the playing file was the one removed, playback advances to the next remaining file.

**When the audio overlay holds key context** (revealed as Compact or Expanded), arrow keys, `[space]`, `[l]`, and seek act on the audio playlist instead:

| Key | Action (audio overlay has key context) |
|-----|--------|
| `[arrow left]` | Previous track in audio playlist |
| `[arrow right]` | Next track in audio playlist |
| `[space]` | Lift suppression when the pause overlay is active (leaving each playlist's own pause state untouched). Otherwise pause / unpause the audio playlist. |
| `[arrow up]` | Close the audio overlay to Hidden (from either Compact or Expanded). A Files & Tags overlay that is also open stays open; key context returns to the player. |
| `[arrow down]` | Step the audio overlay Compact → Expanded. (Expanded is exclusive and closes the Files & Tags overlay.) |
| `[l]` | Toggle loop on the current audio track |
| `[right option] + [arrow left/right]` | Seek the audio track ∓3 s |

### Manager mode hotkeys

In Manager mode (Stopped state), most playback hotkeys are inactive. The following apply:

| Key | Action |
|-----|--------|
| `[arrow up]` / `[arrow down]` | Move the file selection. In the list this steps one row; in the gallery it steps a full row up/down. Collapses any multi-selection to a single item and scrolls it into view. |
| `[arrow left]` / `[arrow right]` | In the gallery, step the selection one cell left/right. In the list there is no horizontal axis (the keys are consumed without effect). |
| `[enter]` | Play the selected file (enters Player mode starting from it), the keyboard equivalent of double-clicking it. Inactive while a text field (rename, tag input) is focused, where `[enter]` commits that field instead. With nothing selected the key passes through. |
| `[esc]` | Close the window |
| `[delete]` | Ask to move selected file(s) to the system Trash (a confirmation dialog appears) |

Arrow keys are consumed by the file-list/gallery navigation, so they never ring the system beep. The Manager delete confirmation holds key context: `[enter]` confirms, `[esc]` cancels, and other keys are ignored while it is shown.

Audio inlet playback control by keyboard is a Player-mode concern (see Key context above).

### Overlay interaction rules

Overlays in Player mode follow exclusivity and dismissal rules:

- **Files & Tags overlay** — while open, the bottom playback controls' hover trigger is suppressed. Compact audio can still appear on top (via top-edge hover); while compact audio is presented, `[arrow down]` both expands audio to its lower section and closes the Files & Tags overlay. **While the Files & Tags overlay is open, the visual playlist's playback/slideshow is paused** so it cannot advance to the next file while tags are being edited; it resumes when the overlay closes (a playlist the user had paused stays paused).
- **Expanded audio overlay** — exclusive with all other overlays. Opening it closes the Files & Tags overlay. All hover triggers are suppressed while it is shown.
- **Compact audio overlay** — closes automatically when any other hotkey-triggered overlay opens (Files & Tags via `[arrow up]`/`[tab]`, or Expanded audio via `[arrow down]`).
- **Bottom playback controls** — compact and bottom-centered. They live in place but stay transparent until the cursor hovers their footprint, then fade in; they fade out and auto-dismiss when the cursor leaves. They never persist across a stop/start, and are hidden while the Files & Tags overlay is open or while suppressed. There is no on-screen "Back to Manager" button — leave Player mode with `[s]`, the pause overlay's **Stop**, or `[esc]`.

### Pause overlay

Pressing `[p]` (or `[esc]` while playing) activates suppression and shows an opaque overlay on top of the media with two buttons:

- **Unpause** — ends the suppression; every playlist in Playing state continues, while playlists in their own Paused state stay paused.
- **Stop** — returns the video/image playlist to **Stopped** state (exits fullscreen Player mode, shows the playlist in Manager mode in the main window). The audio playlist has its own separate Stop control; the main Stop button does not affect it.

Pressing `[p]` or `[space]` while the pause overlay is shown also ends the suppression.

#### Suppression vs per-playlist pause

Each playlist is always Stopped, Playing, or Paused - a persistent per-playlist state. **Suppression** is a single transient layer on top of those states: actual playback happens only while a playlist is Playing and suppression is off (`playback = playing && !suppression`).

Suppression is active while the pause overlay is shown or the window is closed; when it ends (Unpause, or reopening the window), every Playing playlist continues. Quitting and relaunching the app behaves the same way as closing and reopening the window. Since the pause overlay hides the whole UI, playback controls only ever reflect the playlist states.

**Per-playlist paused state** is set via the play/pause control in a playlist's own playback controls (video/image bottom bar, audio overlay). It persists through suppression, window closing, and quitting/restarting. It is cleared when another playlist of the same kind is made active (video and image playlists also clear each other this way).

## Video player

The video player plays files from the active video playlist one after another in fullscreen.

### Hover zones

- **Top edge** — slides in the compact audio overlay (auto-closes when the cursor leaves; see Audio Player for details).
- **Bottom-center** — a compact playback controls bar lives here, transparent until the cursor hovers its footprint, then fades in: previous, play/pause, stop, next, loop toggle, track progress / scrub, volume slider, and a **file list button** that toggles the Files & Tags overlay. Each control shows a hover highlight; the bar fades out when the cursor leaves.

### Files & Tags overlay

Triggered by `[arrow up]`, `[tab]`, or the file list button in the bottom playback controls. Slides up from the bottom of the screen.

The overlay is a **simplified** view meant for quick playlist/file switching and single-file operations during playback — not the full management surface that Manager mode provides. It has three columns:

1. **Playlist selector** — the playlists of the active visual type (video *or* image), with a `+` to add one from a folder. Selecting a playlist switches the visual channel to it and starts playing it immediately. It does **not** expose full management (no rename, delete, or reorder — those live in Manager mode).
2. **File list & filtering** — the filter UI (tag multi-select, AND/OR switch, saved multi-tag searches — no service-filter toggles, those live in Manager, though a service filter set there is honored here and its banner can clear it), the list of files in the active playlist (always list view, not gallery). If a filter change excludes the currently playing file, the player jumps to the first file that still matches; if nothing matches, the player stays in Player mode and shows a "No files match the filter" placeholder rather than dropping back to Manager.
3. **Tag management** — tag editor for the **currently active file** only (same UI as described in Tag editing UI).

Per-file actions in the list act on a single file:

- **Double-click** — play this file: the player switches to it, resumes if it was paused, and the overlay dismisses so playback continues unobstructed.
- **Rename** the file on disk (the playlist updates in place).
- **Delete** the file (moves it to the system Trash and removes it from the playlist).
- **Show in Finder**.

Bulk operations — multi-select delete and editing tags across a selection — are reserved for Manager mode; the overlay focuses on the active file for fast in-playback edits.

If a file goes missing between when the playlist was built and when playback reaches it, playback silently skips it and the file is removed from the playlist.

## Image player

The image player shows the active file of the active image playlist in fullscreen.

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

- **Top edge** — slides in the compact audio overlay (same behavior as video player).
- **Bottom-center** — a compact playback controls bar (same hover-to-reveal behavior as the video player): previous, stop, next, slideshow on/off toggle, slideshow interval selector, and a **file list button** that toggles the Files & Tags overlay. A play/pause button appears only while a slideshow is running (a still image has nothing to pause).

The Files & Tags overlay works identically to the video player's (see above).

## Audio player

Audio playlists use the same folder / shuffle / tag model as the other types. They are first-class **Manager** content (the audio scope, see Manager mode) and play through a parallel channel that never enters fullscreen independently. The audio channel is controlled from two surfaces sharing one state-dependent transport:

- The **audio inlet** pinned at the top of the Manager left panel, present in every scope.
- The **player-mode audio overlay**, which slides down from the top edge while a video or image plays in fullscreen.

### Audio inlet (Manager mode)

- **No audio playlist is active** — a music glyph and a **Play** that cascades: with no audio playlists, it opens the add-folder flow; with some, it starts the first one.
- **An audio playlist is active** — the state-dependent transport (below). The track name and a thin track-progress bar appear only once a current track is available; an active playlist with no current file yet shows just the transport.

### Player-mode audio overlay

A single overlay with a compact and an expanded state:

1. **Hidden** (default) — nothing is shown for audio.
2. **Compact** — a slim top bar with the current track and the transport (plus track progress / scrub and a volume control). Appears via:
   - **Hovering** over the top edge of the screen — auto-closes when the cursor leaves the overlay area.
   - **`[arrow down]`** from Hidden — stays open until explicitly closed. Does not auto-close on mouse leave; closes on click outside or `[arrow up]`.
3. **Expanded** — the same bar with a lower section revealed: an audio playlists **selector** (with a `+` to add one — selecting a playlist plays it immediately), the active playlist's file list with filtering, and tag management for the current track. Playlist rename / delete / reorder live in the Manager's audio scope, not here. It works during playback.

### Navigation between overlay states

- `[arrow down]` steps forward: Hidden → Compact → Expanded.
- `[arrow up]` closes the audio overlay back to Hidden from either Compact or Expanded.
- A chevron on the compact bar expands and collapses the lower section; a close button dismisses the overlay.

In the **Expanded** state the file list is a simple vertical list, so it does not need left/right arrows for its own navigation: while audio holds key context, `[arrow left]` / `[arrow right]` still switch to the previous / next audio track, and `[arrow up]` progressively closes the overlay. Arrow keys therefore do not move a selection within the Expanded file list (a future revision may add focusable, `[tab]`-navigable zones). The exception is when a text field inside the overlay is in edit mode (e.g. inline rename), where the standard text-editing keys apply — move the cursor, delete the character to the left, delete the selection, and so on.

### Audio controls

The audio transport — shared by the inlet and the overlay — renders only the controls actionable in the current state (no dead buttons): **Stopped** shows Play · Volume; **Playing** shows Previous · Pause · Stop · Next · Loop · Volume; **Paused** shows Previous · Play · Stop · Next · Loop · Volume. Across both surfaces it exposes:

- Play / pause (audio only — sets the audio playlist's per-playlist paused state; separate from `[p]` suppression).
- Previous / next track.
- Stop (returns the audio playlist to Stopped state without affecting the video/image playlist).
- Volume slider (per-playlist, persisted).
- Track progress / scrub.
- Loop toggle — loop current file indefinitely, until un-looped or manually navigated to next file.

### Audio in parallel with video / image

When an audio playlist plays alongside a video, the audio is **mixed** with the video's own audio (the video is not muted). Each playlist keeps and persists its own volume level (relative to system volume level), so the user balances the mix once and the setting sticks for future sessions.

## Playlist switching (Player mode)

Quick switching during playback lives in the overlays' playlist selectors: the Files & Tags overlay's selector for the active visual type, and the expanded audio overlay's selector for audio. Both list one media type, offer a `+` to add a playlist from a folder, and start a playlist playing the moment it's selected.

Full management of every playlist — video, image, and audio — (create, rename, delete, reorder) is available only in Manager mode via the left collapsible panel; the player-mode selectors are quick switchers.
