# Shutapla

A macOS media player that works directly with folders of files on disk. Point it at a
folder and it reads the folder (and its subfolders) recursively into a single shuffled
playlist of one media type — **video**, **image**, or **audio** — and plays the files one
after another in fullscreen.

Files on disk are always the source of truth. Playlists are lightweight snapshots that hold
ordering and filtering, last-played state, and per-playlist preferences — nothing more.

## Highlights

- **Folder-based playlists.** A chosen folder becomes one playlist of a single media type;
  mixed folders prompt you to pick which type to import.
- **Filename tags.** Tags are literally what appears inside a single `[...]` group in a
  filename (e.g. `holiday clip [beach summer family].mp4`). Shutapla reads them, filters by
  tag combinations, and can add or remove tags by renaming the actual files.
- **Parallel audio.** A visual playlist (video or image) can play fullscreen while an
  audio playlist plays in parallel, each keeping its own volume.
- **Manager and Player modes.** A windowed Manager for browsing, tagging, filtering, and
  organizing playlists; a fullscreen Player for playback with quick switching and tag edit.
- **Works with your library where it lives.** Handles cloud/offline files (iCloud Drive
  placeholders) with prefetch-ahead so playback doesn't stall, a find-duplicates tool, and a
  thumbnail cache.

## Supported formats

- **Video/Audio** — wide variety of formats, courtesy of [MPV player](https://mpv.io)
- **Image** — jpeg, png, jpeg xl, gif, and other common formats.

Unsupported files in a folder are skipped silently, with a count surfaced so you know they
exist.

## Requirements

- macOS 26 or later
- Apple Silicon (arm64)

## Install

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **Shutapla**
to your Applications folder.

## Building from source

Open `ShuTaPla.xcodeproj` in Xcode and run the `ShuTaPla` scheme. libmpv is bundled from a
Homebrew install (`brew install mpv`) by a build phase.

## Documentation

- [`doc/features.md`](doc/features.md) — feature spec and terminology
- [`doc/architecture.md`](doc/architecture.md) — system design
