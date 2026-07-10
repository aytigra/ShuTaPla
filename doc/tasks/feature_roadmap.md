# Implementation Tasks

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

