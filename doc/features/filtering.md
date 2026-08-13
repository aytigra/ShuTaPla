> Part of the Shutapla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Filtering and search

The Filter Strip sits at the top of the file list on all three surfaces (the Manager center, the Visual Overlay, and the Audio Overlay), each pointing at one playlist's persisted filter; editing it from any surface edits the one stored filter, and every view that shows that playlist re-derives. It is the single home for everything that narrows a playlist — the tag filter, the saved searches over it, the Service Filters, and the triage counters that set them.

## Current scope

A playlist's tag filter is **four independent tag lists**, AND-joined. There is no match-mode control: the mode *is* which list a tag was typed into.

| Field | Matches |
|---|---|
| **Must have all** | the file carries every tag in the list |
| **Must have any** | the file carries at least one of them |
| **Must not have all** | the file is missing at least one of them (dropped only when it has every one) |
| **Must not have any** | the file carries none of them |

A file matches when all four hold; an empty list is vacuously true, so a filter is "set" when at least one list has a tag in it. Several lists can be filled at once — `A AND B AND (C OR D)` is Must have all `[A, B]` plus Must have any `[C, D]`. A tag may repeat across lists, redundantly or contradictorily (the same tag in Must have all and Must not have any matches nothing); nothing prevents or warns about it.

An **untagged** file — one with no tags at all — carries none of the listed tags and is missing all of them, so it satisfies both negative fields. The filter is **per playlist**, not a single app-wide setting.

A **top-level OR** — `(A AND B) OR (C AND D)` — is out of scope: it needs a real expression builder.

Tags are picked with the same multiselect-autocomplete control as the Tag Editor — selected tags as chips, a typed-into dropdown of matching tags — but in search-only mode: it adds existing tags to the filter and cannot create new ones. One field's dropdown is open at a time, since focusing another field closes the previous one.

### The strip

**Collapsed** it is one row — `› Filter` and `Searches`, plus whatever else the [precedence below](#service-filters) allows beside them. The two buttons say what is set, so the strip needn't be expanded to answer "filtered, by what": an ad-hoc filter tints `Filter`, and an applied saved search replaces the `Searches` label with its name. `Clear` joins them only while a tag filter is set.

**Expanded** in place (the caret is the only control; there is no `esc` binding), it adds the four labelled tag fields in a grid of one, two, or four columns by width, plus the name field and its `Save` / `Delete saved search` button. Expansion is view state — not persisted, not per playlist — so each surface keeps its own.

`Searches` opens a dropdown as wide as the strip, closing on a click elsewhere. Each row is the search's name over a generated summary of its filled fields, with buttons to move it up or down and to delete it (confirmed). Picking and ordering is all it does: a saved search is edited by editing the filter while it is applied.

## Service Filters

Separate from the tag filter, the playlist carries one of two **Service Filters**:

- **Untagged** — files without any bracket group.
- **Invalid tagging** — files with invalid tagging (see [Invalid tagging](tags.md#invalid-tagging)), for stepping through and fixing them.

Each surfaces as a counter in the Manager's Filter Strip, shown only when its count is non-zero; clicking one activates the matching Service Filter. Like the tag filter, an active Service Filter affects playback — only matching files play.

The Filter Strip carries a third counter, **skipped**, which sets no filter. Skipped files — found in the folder but excluded from the playlist as unsupported or of another media type — never play, so they are reviewed as a list rather than filtered into playback: clicking the counter enters the **skipped review**, one of the two transient Manager review modes (the other being [find duplicates](manager-mode.md#find-duplicates)). The center then lists the skipped files for inspection only — Show in Finder, move to Trash — and because that list is not a playback sequence, every play affordance is unavailable while a review mode is up: the Manager `Play` button is disabled, and a double-click or `[enter]` on a row does nothing. The banner's `Done` leaves the review, as does any filter edit, a playlist switch, or a Scope switch.

The Service Filter is persisted on the playlist, alongside the tag filter, and applied uniformly — Manager, the overlays, and playback all honor it — so triaging the untagged or invalid-tagged set resumes across launches.

**A tag filter and a Service Filter can both be set**, and the strip resolves them by precedence, showing exactly one thing at a time:

1. **A review mode** (duplicates, skipped) — its banner and `Done` alone.
2. **A Service Filter** — its "Showing untagged" state and `Show All` alone; the filter controls and the counters are hidden.
3. **A set tag filter** — `Filter` / `Searches` / `Clear`, with the counters hidden.
4. **Nothing set** — `Filter` / `Searches` / the counters.

A tag filter parked under case 2 is hidden, not lost: the Service Filter always carries its way out, and clearing it drops straight to case 3 with the tag filter intact. The Manage Tags panel sits outside this ordering — its row tap sets a one-tag filter and is reachable under any case, so that path clears the Service Filter, without which the tap would land on a filter case 2 is hiding and look like nothing happened.

Filtering affects playback: files that don't match are silently skipped during play (in addition to being hidden from the file list). Whenever the current file becomes unavailable for any reason — it is deleted, goes missing on disk, or is excluded by the current filter — playback advances to the next available file. When nothing remains to advance to — a filter change (or deletions) empties the playable sequence — the two channels diverge: the Visual Channel stays in Player mode showing the "No files match the filter" placeholder, so the filter can be lifted from there; the Audio Channel, which has no such placeholder surface, instead returns its Audio Channel Playlist to **Stopped**. While nothing matches, the Audio Transport's `Play` is disabled — widening or clearing the filter from the strip (in Manager or the Audio Overlay) is what makes it available again.

## Filter persistence and history

- Each playlist remembers its current filter across playlist switches, so returning to a playlist restores it.
- **Saved searches** are playlist-scoped. Any set tag filter can be named and saved from the expanded strip; the name need not be unique, since the summary on the dropdown row is what tells two entries apart. Saving is refused only when another search already covers the same four lists, naming the one that does.
- **A saved search is edited by editing the filter.** While one is applied, tag and name edits land on it directly — there is no update step and no way to fork an applied search into an ad-hoc one. `Clear` lifts it from the playlist and keeps it; `Delete saved search` (confirmed, and matching the dropdown row's delete) removes it along with its tags, leaving the playlist unfiltered.
- The list is unbounded and holds **insertion order**, rewritten only by a row's up/down buttons — applying a search never reorders the list under the user.
- A playlist-wide tag **rename** rewrites the saved searches that used the tag. A tag **removal** drops it from every list of every search, and discards a search only when that leaves all four of its lists empty (its remembered position goes with it) — a search left with any tag anywhere survives.
- Frequently used tags float to the top of the autocomplete dropdown within that playlist, independent of what is saved.
- **Per-filter resume position.** Each saved search and the unfiltered state remembers the resume point it was last left at, recorded as a position on the shuffle order so it survives the exact file leaving the set (filtered out, deleted, or pruned). Changing the filter restores the incoming filter's remembered position — a live audio channel switches to it immediately, a suppressed visual pre-loads it. An ad-hoc filter gets no slot (you never switch *into* ad-hoc, and a relaunch resumes it from the playlist's current file), Service Filters get none either, and Reshuffle clears every remembered position.
