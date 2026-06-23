> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Tag system

Tags are not a separate entity tracked by the app — they are literally what appears inside `[...]` in a filename. Reading tags means parsing filenames; editing tags means renaming files.

## Tag syntax in filenames

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
- A file without any bracket group is **untagged**. Untagged files are surfaced via a counter notice that activates the Untagged Service Filter.
- Removing the last tag from a file also removes the now-empty brackets from the filename.

## Invalid tagging

A file is considered to have invalid tagging when its bracket usage is either ambiguous or would lose information:

- **More than one bracket pair**, or **nested brackets** (which also break the single-pair rule) — the app cannot decide which group holds the tags.
- A single bracket group containing **any** token that is not a valid tag (for example `[beach ab]` or `[a b c]`). Flagging it as invalid keeps that content from being silently discarded on the next tag edit.

A single stray, unmatched bracket that does not break parsing (for example a literal `[` or `]` used in prose) is simply ignored, not treated as invalid. These invalid files are not silently ignored:

- The playlist surfaces a counter notice showing the count of files with invalid tagging; clicking it activates the Invalid tagging Service Filter.
- While that filter is active, the list shows only those files, so the user can step through them and fix each one with a simple rename.
- Until fixed, an invalid-tagged file still plays normally as part of the playlist; it simply does not contribute any tags and is excluded from any tag-based filter (it appears under the Invalid tagging Service Filter).

## Tag cache

When a playlist is created (and after each Update / Reshuffle) the app collects all tags from all filenames in the playlist and caches them as the playlist's known-tags set. This drives the dropdown suggestions in the Tag Editor and the Filter Bar. Adding new tags to files also adds them to the tag cache so they appear in suggestions. Remove/rename tag playlist-wide operations also rename/remove them in the cache.

## Tag editing UI

The Tag Editor's UI and behavior are identical in all three places it appears — the Manager inspector, the Visual Overlay, and the Audio Overlay.

The Tag Editor applies to the **currently selected or active file(s)**. UI is a multi-select tag input:

- Existing tags appear as chips.
- A text input lets the user type freely. As they type, a dropdown shows matching existing tags and commonly used tags from the playlist's cache.

When the selected or active file has **invalid tagging**, the chip editor is not shown — editing by chip would rewrite the filename and risk dropping the bracket content (which could be relevant). Instead the editor displays an **"invalid tag syntax"** message that explains the problem and offers a plain filename-rename field so the user can fix the name by hand. Once the filename parses cleanly (valid or untagged), the chip editor returns automatically. In a Manager multi-selection, files with invalid tagging are excluded from tag add/remove operations and called out so the user can fix them individually.

## Tag input hotkeys

The input does not take focus on its own — clicking the field opens it for editing; clicking outside it (or `[esc]`) gives focus up. While it is focused, all keys are captured by the Tag Editor and do not trigger player or overlay actions.

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
