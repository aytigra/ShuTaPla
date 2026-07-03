# Manager: dimensions & size display + adjustable gallery width

Two independent Manager-mode features, tracked together:

1. **Show a file's pixel dimensions and on-disk size** in the file list and gallery,
   alongside the running time that is already shown.
2. **Make the gallery tile width adjustable** per playlist, from a control in the
   playlist Settings popover (min width 100–600, currently the hardcoded
   `galleryMinItemWidth = 200` / `galleryMaxItemWidth = 360`).

The metadata is already cached on `PlaylistFile` (`width`, `height`, `fileSizeBytes`,
`pixelSize`) by the media-metadata-cache work — read once off the main actor on first
display, persisted, instant thereafter. So feature 1 is display-only: no new extraction,
no model change. Feature 2 adds one optional field to `PlaylistPreferences` (a Codable
blob, so decode-safe with no schema migration) and threads it into the grid.

## Feature 1 — dimensions & size

### What each type carries
- **Video**: duration, dimensions, size.
- **Image**: dimensions, size (no timeline).
- **Audio**: duration, size (no picture).

Today the list's whole length column is gated behind `mediaType != .image`, so **images
show no metadata at all** — that changes: every type shows the fields it has.

### Formatting helpers (new)
- `PlaylistFile.dimensionsText -> String?` → `"1920×1080"` (nil until both known). Uses
  the `×` multiplication sign, not `x`.
- On-disk size via `Int64(bytes).formatted(.byteCount(style: .file))` → `"12.3 MB"`.
  Lands as a small extension (`Int.formattedFileSize` or similar) if reused, else inline.

### List (`FileRowView`) — trailing columns, tag chips removed
Right-aligned monospaced caption columns after the filename, one per field the type
carries: `[name] — [dims] [size] [dur]`. Each a fixed-width column so rows keep common
right edges, exactly as `durationColumn` does now.

**Tag chips are removed from list rows.** They duplicate what the filename already shows
(tags are parsed *from* the name), so the row's whole `ViewThatFits`(single-line / stacked)
machinery, the `tagNames` binding, and the private `TagChips`/`TagChip` helpers go. The row
collapses to one `HStack`: name, spacer, then the per-type columns. This also makes the list
consistent with the gallery, whose cells never showed tag chips. Tags remain fully present in
the tag panel and the filters — only the redundant row display is dropped. `FlowLayout` is
still used elsewhere, so it stays.

### Gallery (`FileGalleryView` / `GalleryCell`) — three corner badges
On the thumbnail: **dimensions top-right**, **size bottom-left**, **duration bottom-right**
(the existing badge, unchanged). Images have no duration (bottom-right empty); audio has no
gallery. All three share the existing badge chrome (dark rounded pill, white monospaced
caption). If this reads too busy in practice, a follow-up can reveal the badges only on
hover/focus of the tile — not done initially.

### Tests
- `dimensionsText` formatting (both-known, one-missing → nil, the `×` glyph).
- File-size formatting wrapper if extracted.
- Row/cell composition is view-layer; covered by the pure formatting helpers plus a
  visual check (no view-inspection harness in the project).

## Feature 2 — adjustable gallery tile width

### Storage
Add to `PlaylistPreferences`:
```swift
/// `nil` falls back to `FileCollectionLayout.galleryMinItemWidth` (200).
var galleryMinItemWidth: Double?
```
Per-playlist because the Settings popover is per-playlist.

**Needs a schema migration (assumption corrected — verified by a `loadIssue` crash).**
`Playlist.preferences` is a *single* Codable struct property (no `@Attribute`), so SwiftData
stores it as a **structured composite attribute** whose member fields are part of the entity's
schema hash — *not* an opaque blob (that's only how the `[SavedSearch]` array rides). Adding
even a nilable field changes SchemaV4's realized hash while its `versionIdentifier` stays
`4.0.0`, so an existing on-disk store fails to load at runtime (`loadIssueModelContainer` →
the `fatalError` in `ShuTaPlaApp.init`), crashing the app/test host before anything runs.

So this is a real versioned-schema bump, mirroring V3→V4:
1. **Freeze SchemaV4** to the old shape — nested `@Model` `Playlist`/`PlaylistFile`/`Tag`, with a
   **frozen copy of `PlaylistPreferences`** (without `galleryMinItemWidth`) referenced by the
   frozen `Playlist` (the live struct already carries the new field, so the frozen model can't
   reuse it).
2. **SchemaV5** — current, live types, `versionIdentifier` `5.0.0`.
3. `AppMigrationPlan` — append `SchemaV5` and a `.lightweight(fromVersion: SchemaV4, toVersion: SchemaV5)` stage.
4. `ShuTaPlaApp` — `Schema(versionedSchema: SchemaV5.self)`.
5. A `MigrationTests` case: write an old-V4 store, reopen through the plan as V5.

### One knob, derived max
The grid is `.adaptive(minimum:maximum:)`. Rather than expose both bounds, keep the
current `max / min = 360 / 200 = 1.8` ratio and derive `maximum = min * 1.8` from the
one slider value. `FileCollectionLayout.galleryMinItemWidth` stays as the **default**
(200); a `galleryMaxRatio = 1.8` constant replaces the standalone max.

`FileCollectionView.columns` reads `playlist.preferences.galleryMinItemWidth ?? default`
and derives the max. The keyboard column-count derivation is unaffected — it measures the
real laid-out cell edges, not the constants.

### Control (`PlaylistSettingsView`)
A new `Section("Gallery")`, shown for **image and video** playlists only (audio has no
gallery), with a `Slider(value:in: 100...600, step: 20)` bound to the preference
(nil → default while untouched), and a trailing label showing the current px value.
Edits write straight to the model (no coordinator involvement — the grid is Manager-only).

### Tests
- `columns`/metrics derivation is pure enough to unit-test: min value → (min, max) pair
  with the ratio; `nil` → default. Extract a small `FileCollectionLayout.gridMetrics(min:)`
  helper so the derivation is testable without the view.
- Preference round-trips (set → persisted value; nil → default) — pure model test.

## Steps (one at a time, tests lead)
1. ✅ **F1 helpers + tests** — `dimensionsText`, file-size formatting; unit tests first.
2. ✅ **F1 list** — `FileRowView`: per-type trailing columns (images included) and remove
   the tag chips / `ViewThatFits` machinery.
3. ✅ **F1 gallery** — `GalleryCell`: dimensions top-right, size bottom-left badges.
4. ✅ **F2 storage + metrics** — `galleryMinItemWidth` pref (with the SchemaV5 migration +
   `MigrationTests`, see Storage), `gridMetrics(min:)` helper + tests, thread into
   `FileCollectionView.columns`.
5. ✅ **F2 control** — `Section("Gallery")` slider (100–600, step 20) in `PlaylistSettingsView`.
6. ✅ **Docs + checklist** — update `doc/features/manager-mode.md`; navigator issues; dedup pass.

## Decisions
- **List**: A1 trailing columns; **tag chips removed from rows** (redundant with the name).
- **Gallery**: dimensions top-right, size bottom-left, duration bottom-right; hover-reveal
  is a possible follow-up only if too noisy.
- **Gallery width**: single slider, coupled max via the 1.8× ratio, step 20.
