# Task — Manager "currently edited" selection preview

Make the Manager tag editor's out-of-view editing legible instead of confusing.

## The problem

In the Manager, editing a selected file's tags can push it out of the effective filter (classic
case: "untagged" mode, add the first tag → the file is no longer untagged → it leaves the visible
list). The tag editor keeps the file and you can keep editing it — which is the *desired* workflow
(add several tags to a file that dropped out after the first). But there is no indication of what
you're still editing: the list no longer shows the file, and the editor's header is a generic
"File Tags" / "Common Tags". You can't tell what the tag field is acting on.

This stays a **feature**, not a bug — we don't force the file back into the list (that would make the
filter mean something other than what it says, and needs edit-lifetime pinning logic). We make the
out-of-view selection *visible* with a preview below the tag edit field.

## Current behavior (mechanics)

- The Manager editor is fed by `AppState.selectedManagerFiles()` (`AppState.swift:282`): resolves
  `managerSelection` from the store, **filter-independent** — so it keeps returning a file after the
  file leaves the effective filter.
- `AppState.managerSelectionFiles()` (`AppState.swift:296`) is the *visible* subset — the selection
  intersected with `managerFileIDs`. Used by batch actions/confirmations, not the editor.
- Nothing clears `managerSelection` on a data-driven filter recompute. `reseedManagerSelection()`
  (`AppState+Filtering.swift:99`) runs only on an explicit scope/filter *change*, not when
  membership shifts under a stable filter.
- The Visual Overlay's tag column already shows `current.fileName` above the same `TagEditorView`
  (`LibrarySurface.swift:220`); the Manager is the one surface with no filename. It is also
  single-file (the playing/preview file), so it needs no multi-file treatment and is **out of scope**
  here — this task touches only the Manager sidebar.

### The scope asymmetry (intended, kept as-is)

| Action | Resolves | After all selected files filter out |
|---|---|---|
| Tag editor add/remove | `selectedManagerFiles()` — whole selection | still edits them (the feature) |
| `[delete]` hotkey / batch actions | `managerSelectionFiles()` — visible only | resolves empty → **safe no-op** |
| Row context-menu Delete | the explicit file | still deletes that file |

`requestDeleteSelectedFiles()` (`AppState+Confirmations.swift:23`) guards on the visible set being
non-empty, so a bare `[delete]` never trashes files that filtered out from under you. Keep this. The
preview's summary is what explains the otherwise-mysterious inert `[delete]`.

## Design (settled)

A read-only preview **below the tag edit field**, at the bottom of the Manager filter-and-edit panel
(`TagSidebar.filterAndEdit`). The panel is a `ScrollView`, so the preview can grow/scroll without
displacing the filter and edit controls (which stay adjacent at the top).

- **One file selected** → a read-only `GalleryCell` (thumbnail + name + badges) as the preview. Its
  filename caption comes from `GalleryCell` for free — no extra label.
- **More than one selected** → a summary line, then a plain list of the selected files' names (no
  per-row marks, no dimming). The name list can be long → render it lazily and let it **scroll within
  the available space**, not grow the whole sidebar (see the layout note below).
- **Summary line** (multi-file, above the list). Always present; only the filtered-out variants carry
  an exclamation/info icon:
  - none filtered out → `"N selected"` (plain, no icon)
  - some (but not all) filtered out → `"N selected · M filtered out"` (icon)
  - **all** filtered out → `"All filtered out"` (icon; not "N selected · N filtered out")
- **Nothing selected** → no preview (the editor already shows its own "Select files…" hint).

### Layout — the long list needs its own bounded scroll

`TagSidebar.filterAndEdit` is currently one outer `ScrollView`. Dropping a possibly-very-long name
list inside it would just make the whole sidebar grow unboundedly. Instead, restructure so the top
controls (`FilterBar`, `TagEditorView`, and the summary line) stay fixed and the **name list owns the
remaining vertical space with its own scroll** — a `List`/`ScrollView` + `LazyVStack` sized to
available height, so long selections scroll internally without pushing the filter/edit controls off
screen. The single-file `GalleryCell` branch has no list and no scroll concern.

### Naming refactor (part of the work)

The two accessors barely differ in name despite meaning "editor scope" vs "visible-action scope".
Rename for clarity and add a count helper:

- `selectedManagerFiles()` — keep (the whole selection; what the editor edits).
- `managerSelectionFiles()` → `visibleSelectedManagerFiles()` (the visible subset; action scope).
- add `filteredOutSelectionCount` (or a helper returning the filtered-out rows) so the summary reads
  `selectedManagerFiles().count - visibleSelectedManagerFiles().count` behind one name.

Update all call sites (confirmations, preview, `AppState+Preview`, playback reads that use the
visible variant).

### Reactivity & resolution

- The preview view must read `appState.managerSelection` **and** `appState.managerFileIDs` in its
  body: `managerSelection` is `@Observable`-tracked, and `managerFileIDs` touches the tracked
  `PlaybackSequences.version` (bumped by `persistAndRefresh`), so the preview refreshes both when the
  selection changes and when a tag edit shifts membership.
- Resolve the selected rows via `appState.file(for:)` (a `model(for:)` lookup, as `FileGalleryCell`
  does) — **not** a new `includePendingChanges=false` fetch, which would risk refaulting a dirty row
  mid-edit (the `AppState.swift` refault rule). Filtered-out = id in `managerSelection` but not in
  `Set(managerFileIDs)`.
- `GalleryCell` is pure presentation (tap/menu live in `FileGalleryCell`), so a read-only instance is
  clean: compute `isSelected`/`isCurrent`, `isRenaming: false`, `isStripping: false`,
  `draftName: .constant("")`, no-op rename closures.

## Steps (one at a time, test-first, confirm before each)

**Status:** Step 1 done. Step 2 done.

### Step 1 — Naming refactor + filtered-out count

Rename `managerSelectionFiles()` → `visibleSelectedManagerFiles()`, add the filtered-out count
helper, update all call sites. Pure rename + additive helper; no behavior change.

- **Test first:** add/adjust a unit test that seeds a playlist, selects a subset, applies a filter
  that excludes some of the selected files, `save()`s, then asserts: `selectedManagerFiles()` returns
  all selected; `visibleSelectedManagerFiles()` returns only the still-visible ones; the count helper
  equals the difference. (Hold the `ModelContainer` for the whole body; `save()` before the fetches —
  the fetch-in-accessor / seed-then-read rules.)

### Step 2 — Manager selection preview view

New `Views/ManagerSelectionPreview.swift`, rendered below `TagEditorView` in
`TagSidebar.filterAndEdit`. Single-file `GalleryCell` branch; multi-file summary + marked name list;
wording per the design above.

- **Test first:** the summary line's text (and whether it carries the icon) is the testable core —
  extract it as a pure helper (e.g. `(selectedCount, filteredOutCount)` → text + hasIcon) and
  unit-test the three outcomes ("N selected" no icon, "N selected · M filtered out" icon, "All
  filtered out" icon). The single-vs-multi branch and SwiftUI assembly stay thin around it.
- Check the issue navigator after it builds (deprecations/concurrency), per the definition of done.

**Implementation note:** `filteredOutSelectionCount` was rewritten to resolve through identifiers
(`fileIdentifier(for:)` + `managerFileIDs`) instead of `selectedManagerFiles()`. The preview renders
`GalleryCell`s that merge metadata onto models (leaving them dirty), so reading a count backed by an
`includePendingChanges = false` object fetch during a preview render would refault and discard that
merge — the identifier-only path avoids it while keeping the same result and reactivity.
`ManagerSelectionSummary` is `nonisolated` so its pure logic is unit-testable off the main actor (the
app target defaults to main-actor isolation).
