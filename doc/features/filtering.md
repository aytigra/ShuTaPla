> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Filtering and search

The Filter Bar appears on all three surfaces (the Manager inspector, the Visual Overlay, and the Audio Overlay), each pointing at one playlist's persisted filter; editing it from any surface edits the one stored filter, and every view that shows that playlist re-derives.

## Current scope

Each playlist's filter is a single flat multi-select of tags plus a **match mode** applied to the whole selection, chosen from four:

- **All** — the file carries every selected tag.
- **Any** — the file carries at least one selected tag.
- **Not all** — the file is missing at least one selected tag (the complement of All).
- **Not any** — the file carries none of the selected tags (the complement of Any).

An **untagged** file — one with no tags at all — has none of the selected tags and is missing all of them, so it qualifies under both **Not all** and **Not any**. The filter is **per playlist** — not a single app-wide setting — so each playlist's current combination of selected tags and match mode is its own.

Tags are picked with the same multiselect-autocomplete control as the Tag Editor — selected tags as chips, a typed-into dropdown of matching tags — but in search-only mode: it adds existing tags to the filter and cannot create new ones.

## Service Filters

Separate from the tag filter, the playlist carries one of three **Service Filters**: **Untagged**, **Invalid tagging**, and **Skipped**. Each surfaces as a small counter notice in the Manager center's playlist info area (shown only when its count is non-zero); clicking the notice activates the corresponding Service Filter, and clicking it again deactivates it. While a Service Filter is active, the file list shows only its files and the tag filter is temporarily inactive; Service Filters are mutually exclusive with each other.

- **Untagged** — files without any bracket group.
- **Invalid tagging** — files with invalid tagging (see [Invalid tagging](tags.md#invalid-tagging)), for stepping through and fixing them.
- **Skipped** — files found in the folder but excluded from the playlist as unsupported or of another media type; listed for inspection only (Show in Finder, move to Trash) and never play.

Like the tag filter, an active Untagged or Invalid tagging Service Filter affects playback — only matching files play; Skipped files never play, so the playable sequence under the Skipped filter is empty (looping it would have nothing to show). Because of that, while a playlist's active filter is Skipped the Manager Play button is hidden and the Audio Inlet's Play is a no-op.

The Service Filter is persisted on the playlist, alongside the tag filter, and applied uniformly — Manager, the overlays, and playback all honor it — so triaging the untagged or invalid-tagged set resumes across launches. The counter-notice **toggles** that set it live only in the Manager center; the Visual Overlay and the Audio Overlay carry no Service Filter toggles, but they still honor a Service Filter set in Manager (and show its "Showing untagged — clear" banner, which clears it).

Filtering affects playback: files that don't match are silently skipped during play (in addition to being hidden from the file list). Whenever the current file becomes unavailable for any reason — it is deleted, goes missing on disk, or is excluded by the current filter — playback advances to the next available file. When nothing remains to advance to — a filter change (or deletions) empties the playable sequence — the two channels diverge: the Visual Channel stays in Player mode showing the "No files match the filter" placeholder, so the filter can be lifted from there; the Audio Channel, which has no such placeholder surface, instead returns its Audio Channel Playlist to **Stopped** (easy to restart from the Audio Inlet or Overlay).

## Filter persistence and history

- Each playlist remembers its current filter selection across playlist switches, so returning to a playlist restores its filter.
- **Saved searches** are playlist-scoped. Any non-empty tag filter — one or more tags, in any of the four match modes — can be saved for quick re-selection. A saved search captures **both its tag set and its match mode**; selecting it restores that exact combination. Save is offered only for a filter that isn't already saved; re-selecting a saved combination moves it to the top (keeping its remembered position) rather than adding a duplicate. An entry can be removed manually, and the list is unbounded. A playlist-wide tag **rename** rewrites the saved searches that used the tag; a tag **removal** drops a saved search that would be left with one tag or none (its remembered position goes with it) and rewrites any left with two or more.
- Frequently used tags float to the top of the autocomplete dropdown within that playlist, independent of what is saved.
- **Per-filter resume position.** Each saved search and the unfiltered state remembers the resume point it was last left at, recorded as a position on the shuffle order so it survives the exact file leaving the set (filtered out, deleted, or pruned). Changing the filter restores the incoming filter's remembered position — a live audio channel switches to it immediately, a suppressed visual pre-loads it. Service Filters get no slot, and Reshuffle clears every remembered position.

## Future direction (not in scope yet)

Per-search AND/OR toggling and grouped expressions (e.g. `A AND B AND (C OR D)`) are intended but not part of the initial version.
