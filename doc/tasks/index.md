# Implementation Tasks

Tasks 18, 19, 20 are features described in features.md spec but not yet implemented.
Task 17 - intermediate refactor for performance optimization.

Status legend: ✅ = complete (built and tested). Unmarked tasks are not started.

---

## Task 17 — Performance: tag normalization and identifier-based display sequence

Replace the whole-set derivation of `displaySequence` with a store-side, identifier-only one that never materializes a large playlist at once.

**Why.** Deriving `displaySequence` walks every `PlaylistFile` and reads its SwiftData-backed properties (~0.8µs each, paid on every access); a full `fetch()` / relationship materialization of a large playlist costs ~500ms cold (measured at 20k files), and the Manager/overlay lists re-derive on each scope/playlist switch, so a large playlist hitches. The only approach that beats the per-object materialization floor is to not materialize the set: fetch just the ordered identifiers (`fetchIdentifiers`, ~8ms for 20k) and resolve only the visible rows. For tag filtering to move into the store predicate, tags must be a queryable relationship rather than an inline `[String]` blob. (The Task 15 in-memory memo + `fetchCount` is the interim that removed the recurring warm-switch lag; this task removes the cold floor and the memo.)

**Deliverables:**
- Normalize tags into a `Tag` `@Model` — many-to-many with `PlaylistFile`, unique normalized (lowercased) name. **No data migration:** filenames are the source of truth for tags, so the old `tags: [String]` field is dropped and the relationship repopulates from a normal scan/Update (existing data is simply re-parsed). `addTag`/`removeTag`/`renameTagAcrossPlaylist` maintain the relationship and the per-playlist frequency cache; on-disk filename casing is still the source of truth.
- Store `taggingStatus` as a **predicate-queryable scalar** (e.g. an `Int` rawValue column), not the current `String` `Codable` enum — a `#Predicate` comparing the `Codable` enum throws `unsupportedPredicate` ("Captured/constant values of type 'TaggingStatus' are not supported"), so service-filter predicates and `fetchCount` need the scalar form. Relationship scoping (`$0.playlist?.persistentModelID == pid`) and `Bool` (`isSkipped`) predicates already work.
- `displaySequence` / `playbackSequence` derive an ordered `[PersistentIdentifier]` via `fetchIdentifiers(includePendingChanges: false, predicate:, sortBy: [SortDescriptor(\.sortOrder)])` — the effective service/tag filter expressed as a `#Predicate`, the sort done by the store. No whole-set materialization. Retire the in-memory memo from Task 15.
- File list / gallery / overlay lists render lazily over identifiers, resolving each visible row via `modelContext.model(for:)`.
- Triage counts via `fetchCount(FetchDescriptor(predicate:))` (carried over from Task 15).
- Mutations are saved before the sequence is re-derived, so `includePendingChanges: false` reflects them (the load-bearing ordering constraint — covered by tests).

**Testable:**
- Tags rebuild from filenames on scan into `Tag` relationships; filter and count results match the pre-refactor parse for the same filenames.
- `displaySequence`/`playbackSequence` return correct order and membership under no filter, each service filter, and tag AND/OR — matching the pre-refactor results.
- A large playlist switches without materializing all files (identifier fetch; only visible rows resolved).
- Counts match the per-file walk.
- A filter / tag edit / reshuffle, saved then re-derived, reflects the change; an unsaved mutation does not leak a stale or pending row.

---

## Task 18 — Cloud / offline file handling

iCloud/offline awareness: per-file status indicators, on-demand download, and prefetch ahead of playback.

**Deliverables:**
- `CloudFileService.swift` — per-file status (local / in cloud / downloading) via `NSMetadataQuery` scoped to active playlist folders and URL resource values (`.ubiquitousItemDownloadingStatusKey`, `.ubiquitousItemIsDownloadingKey`)
- On-demand download via `FileManager.startDownloadingUbiquitousItem(at:)`
- Prefetch: while the current file plays, request downloads for the next N files in playback order (driven from `PlaybackCoordinator` on each file change)
- Live status published off-main and delivered to `@MainActor` via `AsyncStream`; `CloudStatusBadge.swift` renders "in the cloud" / "downloading" indicators wired into `FileRowView` (list), the gallery, and the Visual Overlay
- Playback integration: if the file playback reaches is still in the cloud, request its download immediately; if it cannot be made local in time, advance to the next available file (same rule as missing files)

**Testable:**
- Status mapping: placeholder/evicted → in cloud, actively fetching → downloading, present → local
- Prefetch requests exactly the next N files in playback order on a file change
- On-demand download requested when playback reaches an in-cloud file
- Download timeout → advance to next available file
- Indicators appear/clear as status changes (mock status provider)

---

## Task 19 — HDR

HDR/EDR output for video and images (the fullscreen/window-management handling this once shared lives in Task 16).

**Deliverables:**
- HDR video: mpv `--target-colorspace-hint=yes`, `MPVOpenGLLayer` EDR (float backbuffer, `wantsExtendedDynamicRangeContent = true`, extended-sRGB colorspace) — landed in Task 11.1; tune/verify on an EDR display here
- HDR images: `CGImageSource` with `kCGImageSourceShouldAllowFloat`, EDR-capable layer
- Per-file HDR-vs-SDR gating and brightness tuning on an EDR display

**Testable:**
- HDR video renders with extended dynamic range on capable display
- HDR image displays with EDR
- SDR content renders normally alongside

---

## Task 20 — Accessibility

VoiceOver and macOS accessibility support.

**Deliverables:**
- All buttons use `Button` (not `onTapGesture`)
- File list rows: `accessibilityLabel` with filename and tag summary
- Tag chips: `accessibilityElement(children: .combine)`
- Collapsible panels: `accessibilityValue` ("collapsed"/"expanded")
- Filter controls: explicit `accessibilityLabel`
- Pause overlay buttons: standard `Button`
- Playback controls: `accessibilityLabel` for icon-only buttons
- Volume sliders: `accessibilityValue` with percentage
- `@ScaledMetric` for custom spacing
- Semantic fonts (`.body`, `.headline`) and colors (`.primary`, `.secondary`)

**Testable:**
- VoiceOver navigation through all interactive elements
- Labels read correctly for buttons, sliders, file rows
- Dynamic Type scaling doesn't break layout
- Light/dark mode renders correctly with semantic colors

---

