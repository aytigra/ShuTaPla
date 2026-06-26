> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Playlists, creation, and switching

## First launch and creating playlists

On first launch, the main window shows a welcome state with a prominent button to add the first playlist.

A playlist can be created in three equivalent ways:

1. Welcome-state button.
2. The New Playlist (`+`) button in the Manager toolbar.
3. The application menu.

Each path opens a folder picker. Once the new playlist's media type is known, the Manager switches to the matching Scope (image, video, or audio) and loads the new playlist as the Managed Playlist, **Stopped** — these paths create it for management without starting playback (an audio creation, like an audio selection, first stops whichever Audio Channel Playlist was live). The Player-mode overlays add a fourth and fifth entry point through the `+` in their playlist selectors; there, consistent with selecting in those overlays, the new playlist **starts playing** immediately on its channel, and the Manager Scope is left unchanged. Stopping the Visual Channel Playlist hands it back to Manager mode as the Managed Playlist, so creation from overlay during Player-mode never has to sync it to Managed Playlist separately; because the Visual Channel only ever holds video or image playlists, stopping it can never enter the Manager managing an audio playlist.

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
- Its state: playback state (Stopped / Playing / Paused), current file, file-position, filter state, search history, frequently-used-tag ordering (see relevant sections below).

### Global settings

- Default slideshow interval (initially 10 s).
- Default file-position persistence — the fallback for the per-playlist setting when a playlist hasn't overridden it (initially off). See [File-position persistence](#file-position-persistence).
- Default image fit mode (initially Fit).

### Reshuffle vs. Update

Each playlist refreshes from disk two ways:

- **Reshuffle** — a toolbar button that re-reads the folder and rebuilds the file list from scratch with a new random order. Last-played position is reset.
- **Update** — re-reads the folder, appends any newly discovered files at the end, and prunes files that have disappeared from disk. Ordering and last-played position are preserved. It runs automatically whenever a playlist is loaded onto a channel or into the Managed slot — including re-selecting the open playlist — so new files appear without a dedicated control.

All folder re-reads (Reshuffle and the automatic Update) run in the **background** without blocking the UI, with a small "sync in progress" indicator shown while a re-read is running.

### Playback order and wrap-around

Files play in the playlist's stored shuffled order. Advancing past the last file wraps around to the first and playback continues — the order is not reshuffled. Stepping to the previous file from the first file wraps to the last. When a filter is active, wrap-around applies to the filtered sequence.

### Playlist states

A playlist is always in one of three states:

- **Stopped (Manager mode)** — the default state when a playlist is selected but not playing. The main window shows the playlist's contents in Manager mode (see [Manager mode](manager-mode.md)). The current file (last-played, or first if none) is highlighted but not playing.
- **Playing** — the playlist's files are being presented one after another. A video or image playlist becomes the Visual Channel Playlist and enters **fullscreen** Player mode. An audio playlist becomes the Audio Channel Playlist and plays through the parallel Audio Channel without changing the main window — it stays controllable from the Audio Inlet, and from the Audio Overlay during video/image playback (see [Audio player](players.md#audio-player)).
- **Paused** — playback is halted.

### Transitions between states

- **Selecting** a visual playlist in Manager mode (from the left playlists panel) puts it in **Stopped** state and shows it as the Managed Playlist. **Selecting an audio playlist** in Manager mode makes it the **Stopped** Audio Channel Playlist; because only one Audio Channel Playlist is ever live, this first stops whichever audio playlist was playing.
- **Selecting** a playlist from the Visual Overlay's selector during Player mode immediately starts **Playing** the selected playlist on the Visual Channel. Likewise, selecting an audio playlist from the Audio Overlay starts it playing on the Audio Channel.
- **Play** (the Manager toolbar's Play button, or the Audio Inlet's / Audio Overlay's Play control) transitions to **Playing**, starting from the playlist's last-played or first file. The position within that file is honored only when file-position persistence is enabled for the playlist; otherwise it starts from the beginning of the file. See [File-position persistence](#file-position-persistence).
- **Double-clicking a file** in a file list (whether in Manager mode or in the Visual Overlay during play) transitions to **Playing** starting from that file. As with Play, the position within that file is honored only when file-position persistence is enabled; otherwise it starts from the beginning.
- **`[p]`** activates Suppression (see [Suppression vs per-playlist pause](playback-controls.md#suppression-vs-per-playlist-pause)); playlist states are unchanged.
- **Stop button** (in the Pause Overlay, or in the playback controls) transitions back to **Stopped** — the playlist returns to its Manager view.
- **`[esc]`** — context-dependent (see [Esc behavior](playback-controls.md#esc-behavior) under Playback controls).

### Concurrent playlists

At any time:

- At most one video playlist OR one image playlist may be in **Playing** or **Paused** state — this is the Visual Channel Playlist.
- At most one audio playlist may be in **Playing** or **Paused** state in parallel with the above — this is the Audio Channel Playlist.
- Any number of playlists may exist in **Stopped** state. Manager mode shows one **Scope** at a time — image, video, or audio — and binds to one Managed Playlist at a time.

Switching to a different visual playlist (within or between video and image) cleanly stops the previous Visual Channel Playlist (it returns to Stopped state) and brings the new one up. In Manager mode the new playlist does **not** auto-start; it appears as the Managed Playlist. In Player mode (via the Visual Overlay's playlist selector) the selected playlist starts playing immediately on the Visual Channel. Selecting a different **audio** playlist in Manager mode stops whichever Audio Channel Playlist was live and leaves the new one as the Stopped Audio Channel Playlist (selecting from the Audio Overlay starts it playing instead). Selecting a different **visual** playlist does not stop the Audio Channel Playlist, which can continue playing in parallel. Each playlist's last-played file is preserved, so returning to it later resumes at that file; whether it also resumes *within* the file follows the rules in [File-position persistence](#file-position-persistence).

### File-position persistence

Two independent mechanisms decide whether playback resumes from an offset inside a file rather than from its start.

- **Lifecycle resume — always on.** The live Visual Channel Playlist and Audio Channel Playlist carry their current file *and the offset within it* as part of their state, persisted continuously regardless of the setting below. Closing and reopening the window, or quitting and relaunching, continues each from that offset, respecting its Playing/Paused state. Only non-Stopped playlists are restored this way, so a playlist you explicitly **Stop** is not lifecycle-resumed — its next start follows the setting below.
- **The file-position-persistence setting — per-playlist preference, off by default, falling back to the global default.** It governs every *other* entry into a file: pressing **Play** on a Stopped playlist, playing a playlist after switching to it, or **double-clicking** a file. When enabled, these resume from the file's last position; when off, they start from the beginning.

In short: relaunch always continues where it was left off; every other start resumes mid-file only when the setting is enabled.

## Playlist switching (Player mode)

Quick switching during playback lives in the overlays' playlist selectors: the Visual Overlay's selector for the active visual type, and the Expanded Audio Overlay's selector for audio. Both list one media type, offer a `+` to add a playlist from a folder, and start a playlist playing the moment it's selected.

Full management of every playlist — video, image, and audio — (create, rename, delete, reorder) is available only in Manager mode via the left collapsible panel; the Player-mode selectors are quick switchers that also Update and recenter the current file of their channel's playlist.
