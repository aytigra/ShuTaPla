# Task 19 — HDR (video first)

EDR/HDR output for HDR video on capable displays. HDR images and brightness/tone tuning are
deferred (see Roadmap slice in `feature_roadmap.md`).

## Problem

HDR video plays back as SDR on an EDR display (IINA renders the same clips correctly).

Current setup, configured **statically once** at layer init:

- `MPVOpenGLLayer` (`MPVVideoView.swift:77-78`): `wantsExtendedDynamicRangeContent = true`,
  `colorspace = extendedSRGB`.
- `MPVClient` (`MPVClient.swift:102`): `target-colorspace-hint=yes`.

## Root cause

`target-colorspace-hint=yes` is meant for mpv's **own** macOS VO, where mpv owns the window and can
query the display's EDR headroom. In the **libmpv render API** path mpv has no window and never
discovers the target is EDR-capable, so it **tone-maps HDR (PQ/HLG) down to SDR before the frame
reaches our framebuffer**. And `extendedSRGB` is an SDR extended-range space, so nothing tells
CoreAnimation's tone-mapper to engage EDR. Net result: SDR on screen.

## Fix — IINA's recipe (identical architecture: libmpv OpenGL render API + `CAOpenGLLayer`)

IINA does **not** use `target-colorspace-hint`. Per file, once video params are decoded it reads
`video-params/primaries`, `video-params/gamma`, `video-params/sig-peak` and:

- If `gamma ∈ {pq, hlg}` **and** `primaries ∈ {display-p3, bt.2020}` **and** the hosting screen
  supports EDR (`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0`):
  - **Layer:** `wantsExtendedDynamicRangeContent = true`;
    `colorspace = displayP3_PQ` (display-p3) or `itur_2100_PQ` (bt.2020).
  - **mpv:** `target-prim = <primaries>`, `target-trc = pq`. This stops mpv tone-mapping to SDR and
    makes it emit the PQ signal into the float backbuffer, which the P3/2020-PQ layer colorspace
    then hands to the OS tone-mapper → real EDR.
- Otherwise (SDR content, `bt.709`, or SDR display): `wantsExtendedDynamicRangeContent = false`,
  sRGB / screen colorspace, `target-prim/target-trc/target-peak = auto`.

Reference: IINA `VideoView.swift` `requestEdrMode()` (PR #3539); mpv PR #8485; Apple "Displaying
HDR content in a Metal layer" / `wantsExtendedDynamicRangeContent`.

The 64-bit float backbuffer (`kCGLPFAColorFloat`, `kCGLPFAColorSize 64`) is already correct and
stays — it's what lets EDR values exceed 1.0. The static `extendedSRGB` colorspace and
`target-colorspace-hint` go away.

## Integration seams (ShuTaPla)

- `VideoPlaybackEngine` (`@MainActor`, owns both `client` and `renderView`) orchestrates: it already
  consumes client events, so it computes the decision and applies it.
- `MPVClient` needs synchronous `video-params/*` getters (mirroring `volume`/`isLooping`) and a
  string property setter for the `target-*` options.
- Trigger moment: when `dwidth`/`dheight` first arrive (already observed) — decode is up, so params
  are valid.
- `MPVOpenGLLayer` becomes "dumb": defaults to SDR, exposes one `apply(config)` method.

## Decisions (settled with user)

- **Scope:** HDR **video only** now. HDR images (`CGImageSource` + EDR layer, a separate non-mpv
  path) is a later step.
- **Brightness:** `target-peak = auto` (passthrough) first. Display-peak detection
  (`NonReferencePeakHDRLuminance`) + tone-mapping algorithm deferred.
- **Display migration:** deferred (re-evaluate EDR on window moving between displays). Correct on the
  display the window opens on is enough for now.
- **Metadata caching:** deferred to step 4, **not** bundled into the core fix. Rationale: the
  `video-params/*` read is a fast in-memory read (µs), not a decode — it's only decode-gated for
  *availability*, which happens anyway to play. Caching does **not** speed the read; it only buys
  (a) pre-setting the layer to PQ at load to avoid a possible SDR→HDR first-frames flash, and (b) an
  HDR badge without decoding. Those are worth a separate step once passthrough is verified, but not
  worth folding a SwiftData schema migration + a second extractor change into the unverified core.
  Note: persisted `width`/`height`/`duration` come from the off-main-actor extractors
  (`MediaMetadataService` / thumbnailer), **not** the engine's `dwidth`/`dheight` events — so
  caching HDR-ness means extending those extractors, plus a `PlaylistFile` schema migration
  (see `doc/versioning.md`).

## Steps (implement one at a time, after confirmation)

1. **Pure decision function + tests. ✅ done.** `(gamma, primaries, displaySupportsEDR) → EDR config | SDR`.
   Unit-test every branch: PQ+bt.2020 → itur_2100_PQ + EDR on; hlg+display-p3 → displayP3_PQ + EDR
   on; bt.709 → SDR; unknown primaries → SDR; SDR display → SDR even for PQ content. No wiring — the
   safe, testable core (the layer/GL wiring can't run in the test host).
   - **Shape (implemented):** `struct HDRVideoConfig: Equatable` in `ShuTaPla/MPV/HDRVideoConfig.swift`.
     Fields: `extendedDynamicRange: Bool`; `colorSpace: ColorSpace` (pure enum `.sRGB` /
     `.displayP3_PQ` / `.itur_2100_PQ` — the layer maps the case to a concrete `CGColorSpace`, so the
     decision stays testable without a GL surface); `targetPrimaries` / `targetTransfer` /
     `targetPeak: String` (the mpv `target-prim` / `target-trc` / `target-peak` values, `"auto"` for
     SDR/passthrough). `static let sdr` is the SDR result; `static func decide(gamma:primaries:
     displaySupportsEDR:)` is the branch. Tests: `ShuTaPlaTests/HDRVideoConfigTests.swift`.
2. **Client plumbing. ✅ done.** `MPVClient`: synchronous `video-params/gamma|primaries` getters;
   string setter for `target-prim`/`target-trc`/`target-peak`. Remove `target-colorspace-hint=yes`.
   - **Shape (settled with user):** one generic pair mirroring `volume`/`isLooping`'s queue
     discipline, not six named properties — `func stringProperty(_ name: String) -> String?`
     (`queue.sync`, `mpv_get_property_string`, `nil` when unavailable/terminated) and
     `func setStringProperty(_ name: String, _ value: String)` (`queue.async`,
     `mpv_set_property_string`, `isTerminated`-guarded). The engine calls
     `client.stringProperty("video-params/gamma")` / `client.setStringProperty("target-trc", "pq")`.
   - **sig-peak deferred:** `decide` consumes only `gamma`+`primaries`, so no dedicated sig-peak
     getter now — the generic `stringProperty` reads it whenever the deferred brightness/badge
     steps (4/5) need it.
   - **Tests:** setter round-trip (`target-trc` → `pq`, no file needed); getter reads
     `video-params/primaries` after a lavfi video source decodes under `.audio`/`vo=null` (raw
     `vo=null` client, no GL, no model teardown — trap-safe).
3. **Layer + engine wiring. ✅ done — verified on the EDR display (HDR renders with extended range,
   comparable to IINA; SDR unaffected).** `MPVOpenGLLayer` defaults
   to SDR and exposes `apply(config)`; `VideoPlaybackEngine`, on video-params availability, computes
   the decision against the hosting screen's EDR support, sets the `target-*` options on the client,
   and applies the layer config.
   - **Shape (implemented):**
     - `MPVOpenGLLayer.init` sets `apply(.sdr)` instead of the old static `extendedSRGB`; `apply(_:)`
       writes `wantsExtendedDynamicRangeContent` + `colorspace` and `setNeedsDisplay()`. The
       enum→`CGColorSpace` mapping is a `nonisolated extension HDRVideoConfig.ColorSpace.cgColorSpace`
       in `MPVVideoView.swift` (sRGB / displayP3_PQ / itur_2100_PQ). `MPVVideoView.apply(_:)` forwards
       to the layer, mirroring `attach`.
     - `VideoPlaybackEngine` overrides `handle(_:)`: after `super`, on the first positive
       `.videoWidth` (`dwidth` — stable per file, so once per file) it runs `configureColorOutput()`,
       which reads `video-params/gamma|primaries` via `client.stringProperty`, checks
       `renderView.window?.screen ?? NSScreen.main`'s
       `maximumPotentialExtendedDynamicRangeColorComponentValue > 1`, calls `HDRVideoConfig.decide`,
       sets `target-prim`/`target-trc`/`target-peak`, and applies the config to the layer. Applying
       the decided config every file (incl. `.sdr`) is what resets HDR→SDR on a file switch — no flag.
   - **Tests:** the GL/engine wiring can't run in the test host (trap class 3), so the one seam
     provable there is the `ColorSpace → CGColorSpace` mapping (`colorSpaceResolvesToCGColorSpace`
     in `HDRVideoConfigTests`, compared by bridged name). The end-to-end result (HDR renders with
     extended range, SDR unaffected) was verified by hand on the EDR display.
4. **(follow-up) Metadata caching.** Extend the extractors + `PlaylistFile` schema (migration) to
   persist an HDR descriptor; pre-config the layer at load to kill any first-frames flash; HDR badge
   in gallery/list.
5. **(future, deferred)** HDR images; brightness/tone tuning (display-peak + algorithm); display
   migration.

## Testable

- HDR (PQ/HLG, bt.2020 or display-p3) video renders with extended dynamic range on a capable
  display.
- SDR content renders normally alongside (no false HDR on bt.709 / SDR displays).
- Decision function covered by unit tests across all branches (step 1).
