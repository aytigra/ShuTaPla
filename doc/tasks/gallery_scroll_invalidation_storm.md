# Task — Gallery scroll invalidation storm

## Symptom

Gallery scroll is jerky, with a hard CPU spike during scroll and a slowdown that grows the more the gallery
is scrolled. It persists on fully-cached rows (thumbnail + complete metadata), so it is not thumbnail-decode
cost. An Instruments trace (host-Mac SwiftUI template) shows scroll is 100% CPU-bound on the main thread in
SwiftUI AttributeGraph churn — the cost is view **re-rendering**, not decode or SQLite.

The trigger is any ordinary, legitimate save while the gallery/chrome is mounted:

- **Per-cell `PlaylistFile` fills during scroll** — `GalleryCell.task` / `MediaMetadataService.metadata`
  `file.merge` + `trySave`.
- **Playback position every ~5s** — `PlaybackCoordinator.persistTimelinePosition` writes `file.lastPosition`.
  Nothing on screen changes, yet the whole chrome re-renders.

## Mechanism — PROVEN

**Any live `@Query` coarsely refaults *its own entity's* registered instances on *every* store save,
regardless of what actually changed.** SwiftData hands the *same* registered instance to the `@Query` and to
every other view holding it (`let playlist: Playlist`), so the refault fires those instances' per-keypath
observation and re-renders every view that reads any field of them.

The app's two `@Query` sites both vend **every** playlist:

- `PlaylistSidebar` — `@Query(sort: \Playlist.sortOrder) private var allPlaylists`
- `LibrarySurface` — `@Query(sort: \Playlist.sortOrder) private var allPlaylists`

So any `PlaylistFile` fill or `lastPosition` save → store `willChange` → the sidebar's `@Query` re-fetches →
**every `Playlist` instance is refaulted** → the whole chrome/gallery (which reads `Playlist` fields in
`body`) re-renders. That is the storm.

### How it was proven (control chain)

1. **The model/save layer is innocent.** A bare `container.mainContext` with no `@Query` and no view tree:
   inserting an untouched bystander `Playlist`, then saving an *unrelated* `PlaylistFile` or `GlobalSettings`,
   never re-fires the bystander's setters — in-memory *or* on-disk SQLite. (`ObjectRefaultReproductionTests`.)
   So a plain `save()` does not refault registered objects.

2. **`@Query` is the driver.** In the running app, an overlay harness roots a probe tree where no ancestor
   observes the watched `Playlist`, so a wake can only be that instance's own observation firing. With the
   sidebar `@Query<Playlist>` **present**, saving an unrelated `PlaylistFile` *or* `GlobalSettings` woke every
   `Playlist` probe including an app-untouched bystander. With `@Query<Playlist>` swapped for a one-shot
   snapshot, the same saves woke **only** the one changed object (the file cell) — the `Playlist` refault
   vanished.

3. **It is generic to `@Query`, not specific to `Playlist`.** Adding a live `@Query<Tag>` (a model with *no*
   Codable composite field) made an independently-fetched `Tag` instance refault on the same unrelated saves.
   So the Codable composite attributes on `Playlist` were never the cause — any `@Query` does this to its own
   entity's instances.

`setIfChanged` on the derived-fact writers (`file.merge` of `duration`/`width`/`height`/`fileSizeBytes`/
`fingerprint`) is worthwhile hygiene — it drops no-op writes so they never dirty/save — but it is **not** the
fix: a genuinely-changed write dirties the context identically, and the ~5s `lastPosition` save is a real
change. The fix has to remove the `@Query` amplification.

## Fix

Replace the whole-playlist `@Query` in `PlaylistSidebar` and `LibrarySurface` with a snapshot that is
re-fetched **only** when the playlist set genuinely changes (add / delete / rename / reorder) — not on every
unrelated store save. Candidate: an observed `AppState.playlistsVersion` counter bumped by those mutation
paths, with each sidebar re-fetching on its change. Verify against the harness that (a) an unrelated file /
position save no longer wakes any `Playlist` probe, and (b) a real add/rename/reorder still updates the
sidebar.

Once no live `@Query` vends `Playlist`, nothing refaults the shared `Playlist` instances on a per-cell save,
so per-keypath observation holds and only the changed cell re-renders.

## Remaining steps

1. Design the snapshot refresh signal with the user; write the decision into code comments (durable), not
   only here.
2. Implement in `PlaylistSidebar` + `LibrarySurface`, one at a time, verified against the harness.
3. Cover it: a test that a per-file save does not invalidate playlist-observing views, and that a real
   membership/order change refreshes the list.
4. Remove the temp experiment scaffolding: `InvalidationHarness.swift`, its `RootView` overlay,
   `ObjectRefaultReproductionTests.swift`, and any leftover TEMP probes.
