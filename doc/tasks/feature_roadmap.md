# Implementation Tasks

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

