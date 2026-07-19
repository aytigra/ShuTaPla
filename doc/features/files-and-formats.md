> Part of the Shutapla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Supported file formats

The goal is good support for common formats, not exhaustive coverage.

- **Video**: mp4 and webm (including VP9) primarily. Other common formats accepted opportunistically. HDR supported where the OS and display allow.
- **Image**: jpeg, png, jpeg xl, gif, and other common formats. HDR supported where available.
- **Audio**: mp3 primarily, plus other common formats.

Unsupported files in a selected folder are ignored silently. A small, non-intrusive notice in the playlist info area surfaces the count of skipped files so the user knows they exist without cluttering the main UI. Clicking the notice activates the Skipped Service Filter (see [Filtering and search](filtering.md)), which lists the skipped files for inspection — they can be shown in Finder or trashed, but never play.

## Cloud / offline files

Source folders may live in cloud storage (for example an iCloud Drive folder) where files are not always downloaded locally. A live query watches each active playlist's folder and keeps every file's status current as the system evicts and fetches files, so the state below reflects the disk in real time rather than only what was true at scan.

The app surfaces this state per file, alongside the on-disk size:

- An **"in the cloud"** indicator (`icloud`) marks files that are not yet downloaded (placeholder / evicted).
- A **"downloading from cloud"** indicator (`icloud.and.arrow.down`) marks files that are actively being fetched.

These indicators appear in the Manager list and gallery and in the audio transport; a fully local file shows no indicator. To avoid stalls, the app **prefetches ahead**: while the current file plays, it requests the download of the next files in line (default: the next 3) so they are ready by the time playback reaches them.

Two unavailable cases are handled differently when playback reaches a file:

- **Evicted** (in the cloud / downloading): the file still exists on disk as a placeholder stub, so playback moves to it normally. The app requests its download and shows a downloading placeholder on the visual stage (the audio channel shows the transport indicator), then plays the file in place the moment its bytes arrive. Video and audio wait for it indefinitely; a slideshow keeps its own cadence and moves on after the interval whether or not the image finished downloading.
- **Missing** (recorded as local but gone from disk before a rescan pruned it): silently skipped to the next available file, in playback order.
