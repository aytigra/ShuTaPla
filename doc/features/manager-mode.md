> Part of the ShuTaPla [feature spec](../features.md). Capitalized terms are defined in the [Terminology](../features.md#terminology) glossary.

# Manager mode

Manager mode is the main-window view of a playlist when it is in the Stopped state. It is also the view the user returns to after pressing Stop.

In Manager mode the window content is laid out as panels — no overlays are used. The Audio Channel's playback and state are controlled inline from the Audio Inlet rather than through an overlay.

## Scopes

The Manager binds to **one playlist at a time** — the Managed Playlist — and the whole view (sidebar, center file list, Filter Bar, tag inspector) binds to it, adapting to its type. Switching Scope with the toolbar's Scope Tabs changes only which type of playlist the sidebar lists to pick from; it is not a routing state and does not directly affect the rest of the Managed Playlist's views.

| Scope | Sidebar shows |
|---|---|
| **Image** | Image playlists |
| **Video** | Video playlists |
| **Audio** | Audio playlists |

Switching Scope is the browse gesture: it never starts or stops any channel directly, and pre-loads that Scope's last-managed playlist into the Managed slot (so switching to a type you haven't browsed shows the placeholder). Each playlist carries its own persisted filter, Service Filter, and current file, so those follow the playlist rather than the Scope; the selection belongs to the Managed Playlist. Audio is first-class Manager content — it reuses the same sidebar / center / filter / tag machinery as the visual types, minus the gallery view. The Scope is persisted, as is each visual type's last-managed playlist, so Manager reopens to where you left it (defaulting to video). Image and video Scopes have dedicated last-managed playlist handles; audio does not need one, because the Audio Channel Playlist doubles as audio's last-managed playlist.

## Layout

- **Toolbar** — replaces a window-title strip. Left: the Scope Tabs and the New Playlist (`+`) button (which opens the add-folder flow, then switches to the created playlist's Scope and loads it as the Managed Playlist). Center: the Managed Playlist's name as the window title (placeholder "\(app_name)" when nothing is loaded), and its type's actions — image/video: Play · Reshuffle · List/Gallery toggle · Settings; audio: Reshuffle · Settings. Right: the tag controls (Manage Tags, the tag-inspector toggle). Clicking the *active* Scope Tab collapses the left panel; clicking any Scope Tab while collapsed expands it and sets that Scope. Image/video **Play** enters fullscreen Player mode on the Visual Channel; audio has no toolbar Play (audio playback is independent of the Visual Channel — it can start from the Audio Inlet or from the Audio Overlay, and in both cases does not affect Player mode).
- **Left collapsible panel** — pinned at the top, the **Audio Inlet** (present in every scope, since the Audio Channel is parallel to whatever is being browsed; see [Audio player](players.md#audio-player)). Below it, the active Scope's **playlist list** with full management (create via the toolbar's New Playlist, inline rename, delete, drag reorder). A playlist with a background re-scan in progress shows a spinner in place of its file count; deleting a large playlist clears the selection at once and the row shows a red progress spinner while its data and files are cleaned out in the background, staying visible until removal completes.
- **Center** — counter notices for untagged / invalid tagging / skipped files (each activates its Service Filter — see [Service Filters](filtering.md#service-filters)), and the file list respecting the active filter. Serves the Managed Playlist.
- **Right collapsible panel** — Tag management, shown in one of two modes selected from a toolbar button next to the panel's show/hide control. The default mode shows filtering controls (tag multi-select, AND/OR switch, saved multi-tag searches), and a file(s) Tag Editor for the currently selected file(s) in the center (the same multi-select tag input described under [Tag editing UI](tags.md#tag-editing-ui)); its heading reflects the selection — **File Tags** for a single file, **Common Tags** for a multi-selection (add/removes tags shared by ALL selected files). The toolbar button switches the panel into **Manage Tags** mode (see [Playlist-wide tag operations](#playlist-wide-tag-operations)) and back; entering it reveals the panel if it was hidden. It edits the Managed Playlist.

## File list view modes

For video and image playlists, the file list can be shown as:

- **List** (default).
- **Gallery** with thumbnails.

The choice is persisted per playlist. Audio playlists always use list view.

For video and audio playlists, each file shows its running time: a right-aligned column in the list (after the tag chips, which keep a common right edge), and for video also a badge in the bottom-right corner of the gallery thumbnail. The length is read on first display and cached, so it appears instantly on later displays and across launches. Images have no timeline and show no length.

A file's pixel dimensions and on-disk size are read and cached the same way — off the main actor on first display, riding the file open that already happens for the running time (or, for images, a cheap header read), so no extra pass is needed. They too persist across launches. Their first use is the preview card, which opens at the media's true shape immediately once the dimensions are cached.

## File interactions

- **Click** — select a file (also focuses it for the tag panel).
- **Double-click** — enters Player mode starting from that file (always from beginning of that file, resets file-position).
- **`[space]` (preview)** — with **exactly one** file selected in a video or image playlist, opens a controls-free floating card, centered over a dimmed backdrop below the toolbar, that peeks at just that file — leaving the playlist, the live audio channel, and the window mode untouched (the preview runs on its own playback engine). The card is sized to the media's aspect ratio: a video plays from the beginning, loops forever at the playlist's volume, and carries a thin non-interactive progress strip along its bottom edge; an image is shown static (no pan/zoom). The card appears at its true shape once the size is known: immediately for an image, and for a video too once its dimensions have been cached from an earlier display — only a video previewed before its dimensions were ever cached waits a beat for mpv's live size. `[space]` again or `[esc]` closes it, and while it is open no other key reaches the file list behind it. Audio playlists have no preview (audio plays inline in Manager); zero or multiple selection does nothing.
- **Multi-select** — standard shift / command click to select multiple files at once. With a multi-selection:
  - **Delete** moves all selected files to the system Trash and removes them from the playlist.
  - **Tag edits in the right panel** apply to all selected files. The chips shown represent the **intersection** of tags across the selection (tags every selected file has). Adding a tag adds it to every selected file (a no-op for files that already have it); removing a chip removes that tag from every selected file.
- **Rename** an individual file is also available as a per-file action (context menu / inline rename).
- **Show in Finder** is available per file.
- **Remove Audio** (video playlists only) strips the audio track from the file — or from the whole selection when invoked on one of several selected files. It is confirmed with the same `[enter]`/`[esc]` dialog as Delete. The video stream is copied, not re-encoded, so it is fast and lossless and works for every container the player can open (including webm/mkv). The original is moved to the Trash as a recoverable backup and the audio-free file takes its place; a file currently on screen is reloaded and resumed at its position. The work runs in the background, with a spinner on each file's row while it processes.

## Playlist-wide tag operations

In addition to per-file and per-selection tag editing, Manager mode exposes operations that act on **every file in the playlist** — letting tags be curated without selecting or opening any file. The right panel's **Manage Tags** mode lists every tag in the playlist with its file count; each row offers:

- **Rename a tag** across all files that have it — inline editing in a field that takes focus immediately, confirmed with `[enter]` and cancelled with `[esc]`. Renaming onto a tag that already exists is refused with a message rather than silently merging the two.
- **Remove a tag** from all files that have it. Because this renames files on disk and can't be undone, it asks for confirmation first.

Both operations rename the underlying files on disk to match. When removing the last tag would leave a file with an empty name (a name that is only its bracket group), the file is renamed to a placeholder base instead of an empty/hidden name.
