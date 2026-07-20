# Task 19 — HDR (video first)

EDR/HDR output for HDR video and images on capable displays. Brightness/tone tuning
(display-peak detection + tone-mapping algorithm) and display migration (re-evaluating EDR when
the window moves between screens) are out of scope for this task.

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

- **Scope:** HDR video (steps 1–3) then HDR images (step 4, a separate non-mpv `CGImageSource`
  path). Video landed first.
- **Brightness:** `target-peak = auto` (passthrough). Display-peak detection
  (`NonReferencePeakHDRLuminance`) + a tone-mapping algorithm are out of scope for this task.
- **Display migration:** out of scope for this task (re-evaluate EDR on the window moving between
  displays). Correct on the display the window opens on is enough.
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

4. **HDR images.** The image channel is not mpv — `ImagePlaybackEngine` decodes a `CGImage`
   off-main and `ImagePlayerView` renders it with SwiftUI `Image(nsImage:)`. Make HDR images
   render with extended range on a capable display; SDR images unaffected.

   **Findings (measured, not assumed):**
   - **Decode was the first fix, and it works.** The old decode used
     `kCGImageSourceShouldAllowFloat: true`, which is *not* the HDR path: a gain-map JPEG decodes
     to its SDR base (headroom 1.0) and there is nothing HDR to show. Switching to
     `[kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]` (WWDC24, macOS 14+) produces a
     genuinely HDR `CGImage` — a probe over `~/pictures_pretty/EDR` (script
     `scratchpad/hdrprobe.swift`) reads `contentHeadroom` 5–8× on the gain-map JPEGs (10-bit,
     `usesITUR_2100TF`) and 8–30× on the PQ AVIFs. This change is **in** and stays.
   - **The SwiftUI display path is the blocker.** With the decode confirmed HDR, SwiftUI
     `Image(nsImage:)` + `.allowedDynamicRange(.high)` still rendered flat SDR on the EDR display —
     twice, including for a correctly-tagged `ITUR_2100_PQ` AVIF. `Image` built from a
     manually-decoded `CGImage` doesn't light up EDR on macOS. Option A (the one-line SwiftUI
     modifier) is therefore refuted and reverted.

   **✅ done — verified on the EDR display (HDR images render with extended range; SDR unaffected).**

   **Settled approach — custom EDR layer** (Apple: "Using color spaces to display HDR content") — **implemented**:
   - `ImagePlaybackEngine.currentImage` is a **`CGImage`** carried straight to the view (the
     `NSImage(cgImage:)` wrap is gone; `CGImage` is `Sendable`, so the off-main decode returns it
     directly). `MediaPreview.image` follows suit, so the Manager peek shares the path.
   - `EDRImageLayer` (`Views/EDRImageLayer.swift`) is an `NSViewRepresentable` over a view whose
     backing layer is a plain `CALayer`. It sets `contents = cgImage` (the `CGImage` carries its
     own HDR colour space — a plain `CALayer` has no `colorspace` property, that's `CAMetalLayer`/
     `CAOpenGLLayer` only), `preferredDynamicRange` (`.high` / `.standard` — the macOS-26 successor
     to the deprecated `wantsExtendedDynamicRangeContent`) gated on the image being HDR **and** the
     hosting screen supporting EDR, and `contentsGravity` from `fitMode`.
   - `HDRImageConfig.decide(fitMode:imageIsHDR:displaySupportsEDR:)` is the pure decision:
     `fitMode → contentsGravity` (`.resizeAspect` = fit, `.resizeAspectFill` = cover, `.center` =
     original) and `preferredDynamicRange` from the HDR + EDR gate — mirroring `HDRVideoConfig`.
     `CGImage.isHDR` (headroom > 1 or a PQ/HLG colour space) reads the HDR flag off the decode.
   - `ImagePlayerView` still owns pan/zoom (`.scaleEffect`/`.offset` wrap the representable); it
     frames to the surface for fit/cover and to the image's natural size for `.original` so a
     picture larger than the surface can still be roamed.
   - **Tests:** `HDRImageConfigTests` covers the `fitMode → contentsGravity` map and the EDR gate
     (7 cases, green). The on-screen EDR result is a by-hand check on the capable display, as in
     step 3.
5. **Metadata caching + HDR badge.** Persist HDR facts so the badge draws without decoding and the
   video layer pre-configures to PQ at load (killing the possible SDR→HDR first-frames flash). Option
   B, settled with user.

   **Storage (settled with user):**
   - `PlaylistFile.isHDR: Bool?` — a flat persisted field, set for **both** video and image. `nil`
     until determined; `true` iff the content's transfer is PQ/HLG (an image via `CGImage.isHDR`, a
     video via its gamma). Drives the badge everywhere and reads without a decode.
   - Video colour strings ride the `MediaMetadata` bundle like every other extracted fact and persist
     to matching `PlaylistFile` columns: `hdrGamma: String?`, `hdrPrimaries: String?` (mpv-style
     `pq`/`hlg`/`bt.2020`/`display-p3`/`bt.709`, `nil` for non-video and until read). Feed
     `HDRVideoConfig.decide` at load so the video layer is pre-set before decode. Images never set
     these.
   - Schema **V9**, a lightweight additive stage (V8→V9) mirroring the V7 `fingerprint` / V8
     `lastModified` precedents: three additive optional columns, existing rows open as `nil` and
     repopulate on next display. `MediaMetadata` gains `isHDR`/`hdrGamma`/`hdrPrimaries`, threaded
     through `merge` / `cachedMetadata` / `invalidateMetadata` / `hasCompleteMetadata` (completeness
     for video/image requires `isHDR != nil` — a determined SDR file is `false`, not `nil`).

   **Detection (either producer, per the existing split):**
   - Video: AVFoundation format-description extensions (`ColorPrimaries` / `TransferFunction`) map to
     the mpv-style strings from the moov atom, no frame decode; the libmpv fallback reads
     `video-params/gamma|primaries` (the existing `MPVClient.stringProperty`) for webm/mkv. `isHDR`
     from the gamma.
   - Image: the thumbnailer already fully decodes each still, so it reads `CGImage.isHDR` there for
     free (the natural producer, like `fingerprint`).

   **Sub-steps (implement one at a time, after confirmation):**
   - **5a. Schema + model plumbing.** `SchemaV9` + `AppMigrationPlan` stage; `PlaylistFile` fields;
     `MediaMetadata` fields threaded through the four helpers. No detection/UI yet. Migration test
     verifies the V9 columns via raw SQLite (trap class 5 — no live cast).
   - **5b. Extractors populate HDR.** Video (AVFoundation extensions + mpv fallback) and image
     (thumbnailer) set the new fields. Tests over the real samples in `test_media/videos/` and the
     HDR stills.
   - **5c. Video layer pre-config at load.** `VideoPlaybackEngine` runs `HDRVideoConfig.decide` from
     the cached `hdrGamma`/`hdrPrimaries` at load (before decode), then re-runs authoritatively when
     live `video-params` arrive. On-screen flash check by hand.
   - **5d. HDR badge.** Gallery + list cells show a badge when `file.isHDR == true`.

## Testable

- HDR (PQ/HLG, bt.2020 or display-p3) video renders with extended dynamic range on a capable
  display.
- HDR images render with extended dynamic range on a capable display (step 4).
- SDR content renders normally alongside (no false HDR on bt.709 / SDR displays).
- Decision function covered by unit tests across all branches (step 1).
