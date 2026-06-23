# Features

This is the entry point to the ShuTaPla feature spec. It holds the overview, the foundational platform notes, and the **Terminology** glossary that the rest of the spec leans on. The detailed chapters live in [`doc/features/`](features/) — load only the one(s) you need (see the [Spec map](#spec-map) below).

## Overview

ShuTaPla is a macOS media player that works directly with files on disk. The user picks a folder, the app reads it (and its subfolders) recursively and produces a single playlist of one media type: **video**, **image**, or **audio**. Playlists are shuffled and played one file after another.

Files on disk are always the source of truth. Playlists are lightweight snapshots that hold ordering, last-played state, and per-playlist preferences — nothing more.

Filtering is driven by tags embedded in filenames. The app reads tags from names, lets the user filter by tag combinations, and can add/remove tags by renaming the actual files.

A Visual Channel Playlist (video or image) can play in fullscreen while an Audio Channel Playlist plays in parallel, with each keeping its own volume.

## Terminology

Capitalized terms below are used precisely throughout this document.

**Modes, channels, and playlists:**

- **Manager mode** — the windowed view for browsing and organizing playlists, their files, tags and filters.
- **Player mode** — the fullscreen view that presents video or image playback.
- **Managed Playlist** — the single playlist Manager mode is bound to; its sidebar, center file list, Filter Bar, and tag inspector all act on this one playlist.
- **Visual Channel** — the shared playback channel for video *or* image, presented in fullscreen during Player mode.
- **Audio Channel** — the independent audio playback channel that runs in parallel with the Visual Channel and never enters fullscreen on its own.
- **Visual Channel Playlist** — the playlist currently loaded on the Visual Channel. It is *transient*: loaded when Player mode starts and ejected on Stop, which exits Player mode and hands the playlist back to Manager mode as the Managed Playlist.
- **Audio Channel Playlist** — the playlist loaded on the Audio Channel. It is *persistent*: it stays on the channel after being loaded (across launches) until another audio playlist replaces it or it becomes unavailable.

**Overlays, surfaces, and concepts:**

- **Visual Channel Overlay** (**Visual Overlay** for short) — the Player-mode overlay for the Visual Channel: a quick playlist/file switcher, filter and single-file Tag Editor that slides up from the bottom of the screen.
- **Audio Channel Overlay** (**Audio Overlay** for short) — the Player-mode overlay for the Audio Channel, with Compact and Expanded states, that slides down from the top edge.
- **Audio Inlet** — the Audio Transport surface pinned at the top of the Manager sidebar in every Scope.
- **Audio Transport** — the shared, state-dependent transport control rendered by both the Audio Inlet and the Audio Overlay.
- **Pause Overlay** — the opaque Player-mode overlay (Unpause / Stop) shown while Suppression is active.
- **Scope** — the sidebar's playlist-type filter in Manager mode (Image / Video / Audio), chosen via the **Scope Tabs**; it selects which playlists can become the Managed Playlist and nothing more.
- **Service Filter** — a playlist's optional non-tag filter (Untagged / Invalid tagging / Skipped), separate from the tag filter.
- **Suppression** — the single transient layer that halts all playback over the per-playlist states (`playback = playing && !suppression`).
- **Key Context** — the routing target (Visual Channel or Audio Overlay) that currently receives arrow / `[space]` / `[l]` / seek keys.
- **Tag Editor** — the multi-select tag-input control used identically in the Manager inspector, the Visual Overlay, and the Audio Overlay.
- **Filter Bar** — the tag-filter control (tag multi-select + AND/OR switch + saved searches) used across those same three surfaces.

## Platform and window

- macOS only.
- Single window. All playlists, overlays, and players live inside it so the user can switch seamlessly between playlists of the same or different media type without losing state.
- Fullscreen presentation for video and image playback.

## Spec map

| Chapter | Covers |
|---------|--------|
| [Files and formats](features/files-and-formats.md) | Supported video/image/audio formats; skipped files; cloud / offline file handling and prefetch. |
| [Playlists, creation, and switching](features/playlists.md) | First launch; creating playlists (folder classification, dominance, Mixed prompt); what a playlist stores; global settings; Reshuffle vs. Update; playback order/wrap-around; the Stopped/Playing/Paused state machine and transitions; concurrent playlists; Player-mode quick switching. |
| [Manager mode](features/manager-mode.md) | The Stopped-state windowed view: Scopes, toolbar/panel layout, list/gallery view modes, file interactions (select, play, multi-select, rename, Remove Audio), and playlist-wide tag operations. |
| [Tag system](features/tags.md) | Tag syntax in filenames; invalid tagging; the known-tags cache; the Tag Editor UI; tag-input hotkeys; on-disk rename semantics and graceful failure. |
| [Filtering and search](features/filtering.md) | Per-playlist tag filter (AND/OR); the three Service Filters; how filtering affects playback; filter persistence and saved-search history. |
| [Playback controls](features/playback-controls.md) | `[esc]` priority chain; Player- and Manager-mode hotkey tables and Key Context; overlay exclusivity/dismissal rules; the Pause Overlay; Suppression vs. per-playlist pause. |
| [Players (video, image, audio)](features/players.md) | The video, image, and audio players: hover zones, the Visual Overlay, image fit modes and slideshow, the Audio Inlet and Audio Overlay, audio controls, and parallel audio mixing. |
