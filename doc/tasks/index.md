# Implementation Tasks

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

