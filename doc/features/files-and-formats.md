> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Supported file formats

The goal is good support for common formats, not exhaustive coverage.

- **Video**: mp4 and webm (including VP9) primarily. Other common formats accepted opportunistically. HDR supported where the OS and display allow.
- **Image**: jpeg, png, jpeg xl, gif, and other common formats. HDR supported where available.
- **Audio**: mp3 primarily, plus other common formats.

Unsupported files in a selected folder are ignored silently. A small, non-intrusive notice in the playlist info area surfaces the count of skipped files so the user knows they exist without cluttering the main UI. Clicking the notice activates the Skipped Service Filter (see [Filtering and search](filtering.md)), which lists the skipped files for inspection — they can be shown in Finder or trashed, but never play.

## Cloud / offline files

Source folders may live in cloud storage (for example an iCloud Drive folder) where files are not always downloaded locally. The app surfaces this state per file:

- An **"in the cloud"** indicator marks files that are not yet downloaded (placeholder / evicted).
- A **"downloading from cloud"** indicator marks files that are actively being fetched.

These indicators appear in every file list (the Manager list and gallery, and the Visual Overlay). To avoid stalls, the app **prefetches ahead**: while the current file plays, it requests the download of the next files in line (default: the next 3) so they are ready by the time playback reaches them. If a file is still in the cloud when playback reaches it, the app requests its download immediately and shows the downloading indicator; if it cannot be made available in time, playback advances to the next available file (unless the file was selected explicitly by double-click from a file list — in that case playback waits for the download to finish).
