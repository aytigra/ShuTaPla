# Preview seeking

Give the Manager preview ("peek") lightbox playback seeking. Today the preview
plays a video looping forever with a **non-interactive** progress strip and no
transport at all. Add two ways to seek the previewed video:

- `[arrow left]` / `[arrow right]` — seek ∓3 s (matching the main player's
  `[right option]+arrow` step). Bare arrows are currently free in the preview
  (swallowed by the router while it's open).
- Click / drag on the bottom progress strip — seek to that fraction of the
  duration; one gesture serves both click-to-seek and drag-to-scrub.

Seeking is inherently **video-only** (images have no timeline). The preview keeps
playing (looping) throughout — seeking just repositions. Scope is deliberately
minimal: no pause control, no hover tooltip, no visible restyle of the strip
beyond the hit area it needs.

## Design

- **Engine plumbing already exists.** `MPVPlaybackEngine` exposes `seek(by:)` and
  `seek(to:)`; `MediaPreview` owns the `videoEngine`. Only a thin forwarding
  surface + call sites are missing.
- **`MediaPreview.seek(by:)`** — guards `mediaType == .video`, forwards to
  `videoEngine?.seek(by:)`. Ignored for image / closed.
- **`MediaPreview.seek(to:)`** — same guard, forwards `videoEngine?.seek(to:)`.
  The view computes `fraction * duration` and calls this.
- **Router.** `HotkeyRouter.handle` intercepts all keys while `preview.isOpen`;
  extend its branch so `[arrow left]`→`seek(by: -3)`, `[arrow right]`→
  `seek(by: +3)` (via new `AppState` entry points, keeping the router thin and
  matching how `[space]`/`[esc]` route through `AppState.closePreview()`). Every
  other key stays swallowed. On an image preview the arrows are still swallowed
  and do nothing (the `mediaType` guard in `MediaPreview.seek`).
- **Strip.** In `MediaPreviewView.progressStrip`, keep the thin visible fill but
  wrap it in a taller (~16 px) transparent `.contentShape` hit zone carrying one
  `DragGesture(minimumDistance: 0)`. Map `value.location.x / width` (clamped
  0…1) → `preview.seek(to: fraction * duration)`. This is the first mouse
  interaction in the otherwise keyboard-only lightbox; the backdrop stays inert.

## Steps

Each step is test-first: exercise the current code, watch it behave, then change.
One step at a time, confirmation before starting each.

- [x] **Step 1 — `MediaPreview.seek` forwarding.** Added `seek(by:)` / `seek(to:)`
  with the `mediaType == .video` guard, forwarding to `videoEngine`. Tests in
  `MediaPreviewTests` via a `RecordingSeekEngine` (window-free audio slot):
  `videoPreviewForwardsSeekToEngine`, `imagePreviewIgnoresSeek`,
  `closedPreviewIgnoresSeek` (the guard-refuter). 16/16 pass, navigator clean.
- [x] **Step 2 — Arrow-key routing.** Added `AppState.seekPreview(by:)` and the
  router's `[arrow left]`→−3 / `[arrow right]`→+3 cases in the preview branch.
  Test `openVideoPreviewSeeksOnArrowKeysAndStaysOpen` observes the seeks via a
  `RecordingSeekEngine` injected as the preview's video factory (moved to the
  shared `AppStateFilesTestSupport`; `managerFixture`/`makeAppState` gained an
  injectable `makeVideoEngine`). 47/47 router tests pass, navigator clean.
- [x] **Step 3 — Strip click/scrub.** `progressStrip` now wraps the thin visible
  fill in a 16 px transparent `.contentShape` hit zone carrying one
  `DragGesture(minimumDistance: 0)` that maps the pointer's x-fraction to a seek.
  The fraction→seconds math lives in the pure `MediaPreviewView.seekTarget(forX:
  width:duration:)` (clamped 0…1, zero-width→0), covered by the parameterized
  `seekTargetMapsClampedFractionToDuration`. 22/22 MediaPreview tests pass,
  navigator clean. The gesture wiring itself is view-layer — verify click/scrub in
  the running app.
- [x] **Step 4 — Docs.** The `doc/features/manager-mode.md` `[space]` bullet now
  describes the arrow-key ∓3 s stepping and the click/drag-to-scrub strip, and that
  seeking is video-only (strip hidden / arrows inert for an image).

## Checklist before done

- Issue navigator clean (no new warnings).
- Follows code conventions; strip/seek logic not duplicated.
- Tests written first, observed red→green where applicable.
- Docs describe the code as it is now (no change-narration).
