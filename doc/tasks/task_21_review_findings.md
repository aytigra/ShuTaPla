# Task 21 — Code-review findings on `fix-video-seek-bugs`

Triage and resolution of the `/code-review xhigh` findings on branch `fix-video-seek-bugs`
(diff vs `main`, 5 commits: HDR video/image pipeline, HDR metadata caching + SchemaV9,
keyframe-step seeking with end-of-file detection, test-fixture migration to bundled resources).

**Review method caveat:** single-pass inline review — no multi-agent verify pass ran, so no
finding carries a CONFIRMED verdict. **Every correctness finding below is a hypothesis.**
Per CLAUDE.md testing rules, each one must be confirmed by a reproducing test observed **red
against the unchanged code** before any fix; a green run refutes the finding and the code is
left alone (the finding gets marked *refuted* here, not fixed).

## Workflow

One finding at a time, in the order below (severity-ranked; reorder if triage shows a
dependency — e.g. F1/F4/F5 all live in the forward-step state machine and may share one fix):

1. **Confirm/refute:** write the reproducing test, run it against unchanged code, record the
   result here.
2. **Fix** (only if red), watch the test go green, run the surrounding suites.
3. Checklist: navigator issues, conventions, simplification pass.

Status legend: `[ ]` open · `[C]` confirmed (red test exists) · `[R]` refuted · `[F]` fixed (red→green) · `[S]` skipped by decision.

---

## Correctness findings

### F1 `[F]` Forward step consumes an unrelated restart — spurious advance after scrub

*User verified in-app 2026-07-23 (after the rework): steps step, scrub+quick-step doesn't
advance, step at end advances, scrubbing behaves.*

`MPVPlaybackEngine.swift:249`

An armed forward keyframe step is consumed by the **next** `playbackRestart` whatever produced
it, and the step's origin is the optimistic `currentTime`.

Scenario: `seek(to: 100)` sets `currentTime = 100` optimistically (line 174) while the
`absolute+keyframes` seek settles at the keyframe at-or-before 100 (e.g. 98.5; ~255 ms settle,
per task 20 measurements). A skip-forward pressed inside that window arms `forwardStep` with
origin 100 (line 197); the scrubber's restart (98.5) arrives first and is read as the step's
landing: 98.5 ≤ 100 → `advanceAfterForwardStep` true → `advanceToNext()` jumps to the next
file mid-video. Same false landing when a quick back-press then forward-press coalesce in mpv.

**Confirmed red** (2026-07-23): `PlaybackEngineTests/forwardStepDuringInFlightScrubDoesNotConsumeItsRestart`
— scrub to 100, step, then `.playbackRestart(98.5, frames: 1)` → `advancedTo == [second]`:
the scrub's restart advanced to the next file. Fails on both expectations, for the stated reason.

#### Fix design (implemented)

Restart bookkeeping in the engine can never be made exact: both scrub surfaces
(`PlaybackControlsBar` slider binding, `MediaPreviewView` drag) emit a `seek(to:)` **stream**
during drag, and mpv coalesces back-to-back seeks (already documented on
`MPVClient.stepKeyframe`), so the number of restarts per seek is unknowable — any
pending-restart counter drifts and a lone in-flight Bool misidentifies queued restarts.
Worse, a step *issued* while a scrub is still seeking **merges into it** in mpv's core, so
the merged seek genuinely lands at the scrub's floor — behind the optimistic origin — and no
restart-matching (not even a per-command `mpv_command_async` reply) can make that landing
read correctly.

So the fix moves step-landing identification into the client, mirroring the existing
`pendingBackStep` pattern:

1. **Defer the forward step past any in-flight seek.** `stepKeyframe(forward: true)` on the
   client queue reads mpv's `seeking` flag: if a seek is in progress, arm
   `pendingForwardStep` instead of issuing; the drain issues the deferred step on the first
   `PLAYBACK_RESTART` that settles with `seeking == false`. This makes coalescing with a
   scrub impossible — the step always executes from a settled position, whose next keyframe
   is provably *ahead* of the scrub's optimistic target (the next keyframe after
   `floor(target)` is `> target`), so the optimistic engine origin stays safe.
2. **Identify the step's own landing by controlled issuance.** The step is always parked
   (`pendingForwardStep`) and released only from a quiescent client state
   (`tryReleaseForwardStep`): event queue drained, mpv's `seeking` false, **and**
   `seekSinceRestart` false — a client-side flag set synchronously by every seek-issuing
   command (scrub, relative seek, keyframe hops, positioned load) and cleared when a
   `PLAYBACK_RESTART` drains. Released this way, the step's seek runs alone, so the next
   restart to arrive is its own landing (`forwardStepInFlight` marks the wait); it is yielded
   as `.forwardStepSettled(position, frames:)`, replacing `.playbackRestart` in `MPVEvent`.
   Position and frames must be sampled **at that restart**: mpv settles the position before it
   displays the landing frame and fires the restart only after the display — sampling earlier
   reads a healthy step's frame count as flat (a false "dead video track").
3. **Engine evaluates only `.forwardStepSettled`.** Arming/disarming (`seek(to:)`, `load`,
   `stop`, backward press) is unchanged; foreign restarts no longer reach the decision at
   all. `loadFile`/`stop` also clear both new client flags so a stale deferred step can't
   fire on a later file's restart (the F3 failure shape, not recreated for the new flag).

Two rejected identity mechanisms, both *refuted empirically* by the real-mpv test
`MPVClientTests/forwardStepDuringScrubSettlesAtItsOwnLanding` and an event-order trace:

- **"Next restart after issuance is the step's" gated on mpv's `seeking` property** — the
  property lags a just-issued seek command (the playloop hasn't picked it up), so a step
  pressed right after a scrub is issued anyway, mpv coalesces the two seeks (trace: two
  `MPV_EVENT_SEEK`, one restart at the merged floored target), and the merged/foreign restart
  is misattributed.
- **`mpv_command_async` reply as the landing** — the trace shows the reply arrives at command
  *processing* time when the seek merges into an in-flight one (position = optimistic
  in-flight target, before the restart), and in-app it precedes the landing-frame display, so
  frames sampled at the reply read flat → every healthy step false-advanced (the
  first-shipped variant; user-reported regression: first step jumps to start / advances).

Remaining accepted sliver: a seek issued between a restart's *generation* and its *drain*
can slip both gates and coalesce with the released step (window ≈ one drain hop, µs); the
cost is one press with wrong end-detection.

Test adaptation: the confirmed-red engine test is rewritten onto the new event surface as
`forwardStepAfterScrubEvaluatesOnlyItsOwnLanding`; the step-landing engine tests swap
`.playbackRestart` for `.forwardStepSettled`; the old restart client test is replaced by
`scrubberSeekEmitsNoForwardStepSettled` (scrub emits nothing on the channel) and
`forwardStepDuringScrubSettlesAtItsOwnLanding` (one settled event, strictly past the scrub
target; note a WAV's keyframe floor lands `10 + ε` at ~10.048, so the assertion bound is
`> 10.0`, the scrub floor's provable maximum).

### F2 `[F]` `.original` fit renders at half size on Retina

`ImagePlayerView.swift:67`

`.original` fit frames the view at pixel-count **points**, while `EDRImageLayer` sets
`layer.contentsScale = backingScaleFactor` with `contentsGravity = .center`, so CoreAnimation
renders the `CGImage` at `pixels / contentsScale` points.

Scenario: a 2000×1000 image in `.original` on a 2× display — `base()` frames the layer at
2000×1000 pt, the layer renders the contents at 1000×500 pt centered: the picture occupies a
quarter of its frame and pan/zoom roams empty margins. The former `Image(nsImage:)` path
rendered full pixel-dims-as-points.

Test idea: unit-test the frame/scale math if extractable; otherwise confirm visually in-app
(2× display) and cover the corrected sizing helper.

#### Fix design (implemented — user chose pixel-perfect semantics)

The layer's *render* is already a true 1:1 — `contentsScale = backingScaleFactor` with
`.center` gravity maps each image pixel to one device pixel. What's wrong is only the *frame*
`base()` wraps around it: pixel counts taken as points, a box 2× the rendered picture on
Retina. `.original` means pixel-perfect (1 image pixel = 1 device pixel, Preview.app's
"Actual Size"; user-confirmed over restoring the former pixel-dims-as-points size), so the
frame shrinks to match the render:

- Frame math extracted verbatim from `base()` into the pure `nonisolated`
  `ImageFitMode.baseSize(imagePixelSize:surface:displayScale:)` (beside the enum) — a
  behavior-preserving extraction whose point is testability, per this finding's test idea.
- Test first (observed red on the extracted current math):
  `HDRImageConfigTests/baseSizeFramesRenderedPicture` — `.original` at `displayScale: 2` must
  yield `pixels / 2` (red: "(2000.0, 1000.0)) == ((1000.0, 500.0)"), scale 1 and `.fit`/
  `.cover` unchanged (green throughout).
- Fix: `.original` divides by `displayScale`; `ImagePlayerView` reads
  `@Environment(\.displayScale)` and passes it through. Green.

Interplay noted, not entangled: F9 (stale `contentsScale` across display moves) stays its own
finding — SwiftUI updates `displayScale` on display moves, so the frame side tracks correctly
either way.

### F3 `[F]` `pendingBackStep` never disarmed — stray backward seek on next restart

`MPVClient.swift:342`

`pendingBackStep` is not cleared by `loadFile`/`stop`/`seek`/`shutdown`. A back-step whose
anchor seek never produces a restart leaves the flag armed; the next unrelated
`PLAYBACK_RESTART` fires the deferred second hop as a stray backward seek.

Scenario: skip-back during a file transition (or with no file loaded) — anchor seek errors, no
restart, flag stays true. The next file's load fires `PLAYBACK_RESTART` →
`completeBackStepIfPending()` seeks the fresh file to `max(0, timePosition() - 0.1)`
`absolute+keyframes`, yanking a resumed file back one GOP (or to 0). Also: back-press followed
quickly by a scrub lands the scrub one keyframe before its target.

Test idea: client/engine test — arm a back step in a no-restart state, load a new file, assert
its start position is untouched.

#### Fix design (implemented)

Root cause: `pendingBackStep` outlives the gesture that armed it. Its only clearer is
`completeBackStepIfPending()`, reached solely from a `PLAYBACK_RESTART` drain — so an anchor
seek that never restarts (no file loaded, mid-transition) strands the flag, and the next
restart from any source consumes it as a stray second hop.

The forward-step flags already model this correctly: `loadFile`/`stop` reset them because a
step in flight belongs to the outgoing file. `pendingBackStep` needs the same treatment, plus
one more site the forward flags deliberately skip — an explicit `seek`. A forward step pressed
before a scrub is held by the `seekSinceRestart` gate and survives the seek on purpose; the
backward step has no such gate — it fires unconditionally on the next restart — so a scrub (or
skip) issued after a back-press must cancel the pending second hop, or the scrub lands one
keyframe short. Clear `pendingBackStep = false` at four sites:

- `loadFile` and `stop` — alongside the existing `pendingForwardStep`/`forwardStepInFlight` resets.
- `seek(to:)` and `seek(by:)` — a new user seek supersedes a pending back-step's second hop.

`completeBackStepIfPending()` issues its own second hop through a raw `command(...)`, not through
`seek(to:)`, so clearing the flag in the public `seek` methods can't cancel the legitimate hop.
`shutdown` needs no clear: `isTerminated` already gates the drain, so `completeBackStepIfPending()`
never runs after it. No `@Model` change → no migration.

Test (real-mpv, `MPVClientTests`): arm a back step with no file loaded (`stepKeyframe(forward:
false)` — the anchor seek errors, no restart, flag stays set), then load the h264 fixture at
`start = 0.55` and pause. The fixture has a single keyframe at 0.0, so a stray keyframe hop
floors the position to 0.0; an untouched load stays at ~0.55. Assert the settled position is
> 0.4. Run red against the unchanged code (lands at 0.0) before applying the fix.

### F4 `[F]` Flat render-update count alone read as EOF — audio-only files skipped

`MPVPlaybackEngine.swift:282`

`advanceAfterForwardStep` treats a flat render-update count as end-of-file, but the count is
also flat when the channel produces no render updates for benign reasons: audio-only files in
a video playlist, or a render context not yet created.

Scenario: extension-typed video playlist (mkv/mp4) plays an audio-only `.mkv` through
`VideoPlaybackEngine` with `keyframeStepping = true` but zero render updates
(`MPVClient.swift:231` increments only via the render-context callback). Forward step: position
lands healthy but `framesAtSettle == framesAtArm == 0` → advance → the file is skipped
entirely on every forward press; likewise before the GL layer's first draw.

Test idea: audio-only fixture through the video-channel engine (vo=null in test host),
forward step mid-file, assert no advance.

#### Fix design (implemented)

Root cause: `advanceAfterForwardStep` OR-s two "each sufficient" EOF signals, and the frames
signal `framesAtSettle == framesAtArm` fires whenever the count is *flat* — but a count of `0`
that stays `0` is not "video hit EOF", it's "video never rendered a frame". The frozen-picture
case the signal targets is a video that *was* displaying frames (count > 0) and then produced
no new one across the step. The benign cases (audio-only file in a video playlist; a render
context not yet created before the GL layer's first draw) have the count pinned at `0` the
whole time. `framesAtArm` is exactly what separates them: a genuinely frozen video was
rendering, so `framesAtArm > 0`; a track with no frames has `framesAtArm == 0`.

Fix: gate the frames signal on the video having actually been rendering.

```swift
settled <= origin || (framesAtArm > 0 && framesAtSettle == framesAtArm)
```

The position signal is untouched, so a genuine no-next-keyframe end (`settled <= origin`) and
the all-tracks-at-EOF restart (position reads 0) still advance. Nothing is lost on the benign
side: an audio-only file that truly ends fires `endFile(.eof)` (handled separately), and a
mid-file forward step lands strictly ahead — position reads progress, so it correctly holds.

No `@Model` change → no migration. Pure static function; `nonisolated`, unchanged signature.

Tests. The frames signal is only meaningfully exercisable through the *pure* function: the
`vo=null` test client never renders, so `client.videoFrameCount` (hence `framesAtArm`) is
always `0` in every engine integration test. That is why the two existing integration tests
that leaned on `frames: 0 → advance` were only ever green by exploiting this very conflation —
they must move off it:

- `forwardStepDecision` (parameterised, pure): **add** the F4 case
  `(origin: 50, settled: 50.24, arm: 0, settle: 0) → advance == false` (an audio-only / no-context
  step landed ahead but never rendered). Red on the unchanged code (`0 == 0` → advance), green
  after. The existing frozen-video case `(50, 50.24, arm: 7, settle: 7) → true` still passes —
  that is where the frozen-advance behaviour now lives.
- `forwardStepWithNoNewVideoFrameAdvances` (integration): **delete**. Its scenario
  (`settled 50.24 > 50, frames 0`) *is* the F4 no-advance case now, contradicting its name; the
  frames signal it meant to integration-test is unreachable on `vo=null` (needs `arm > 0`).
- `deadForwardStepWithNoSuccessorWrapsToStart` (integration): **repurpose** — keep the
  wrap-to-start behaviour but drive "dead" through the position signal
  (`forwardStepSettled(58, …)`, settled == origin) instead of `frames: 0`, since the frames
  signal no longer fires on `vo=null`.

The remaining engine tests are unaffected: `forwardStepThatCannotAdvanceSwitchesFile` and the
stale/scrub cases already advance (or hold) via the position signal or a disarmed step.

### F5 `[F]` Restart-before-eof ordering double-advances — one press skips a file

`MPVPlaybackEngine.swift:244`

*Note: the F1 fix replaced the restart-based landing with `.forwardStepSettled` (the step's
command reply), so this finding's trigger must be re-triaged against the new code: the
suspect ordering is now the step's reply arriving before the stale `eof-reached` flip, which
would advance twice the same way.*

The restart-based advance and the eof-reached advance are two uncoordinated triggers around
the same instant; only the eof-first ordering is guarded (comment at line 247 assumes the eof
path lands first and its load disarms `forwardStep`).

Scenario: a forward step drives every track to EOF — mpv flips `eof-reached` **and** fires
`PLAYBACK_RESTART`. If the restart arrives first (plausible: mpv dispatches property-change
notifications lazily, as this branch's own `MPVThumbnailer` comment documents), it advances to
file B, then the stale `.endFile(.eof)` from file A advances unconditionally again to file C.

Test idea: drive the handler with the reversed event order directly and assert a single
advance.

#### Fix design (implemented)

Re-triaged against the post-F1 code and **confirmed real**: a reproducing test that drives the
settled-first order synchronously — `forwardStepSettled(50, frames: 1)` (settled == origin →
advance to B) then `endFile(.eof)` — goes red on the unchanged handler with
`advancedTo == [b, c]`. The settled path clears `forwardStep`, so by the time the stale eof
arrives there is no armed step to guard it, and `.endFile(.eof)` advances unconditionally a
second time.

Root cause is the asymmetry between the two orderings around one end:
- **eof-first** is already guarded — the eof advance's `load()` disarms `forwardStep`, so the
  later settled event finds no armed step and no-ops.
- **settled-first** is not — nothing tells the eof handler that a forward step already advanced
  past this same end.

The fix restores symmetry with a one-shot marker `forwardStepReachedEnd`:
- The settled handler sets it **only when it advanced to a *distinct* successor**
  (`advanceToNext()` returned true) — the wrap-to-start branch does not set it, since a stale
  eof there merely re-wraps to 0 harmlessly.
- `.endFile(.eof)` consumes it: if set, clear it and return (the eof-reached flip is the same
  end reported twice); otherwise advance as before.
- `.fileLoaded` clears it. This is the essential bound: when the forward step reached only the
  *last keyframe* (no next keyframe) mpv may never flip `eof-reached`, so the paired stale eof
  never comes — the newly-loaded successor's own `.fileLoaded` (which always precedes that
  file's genuine natural eof) clears the marker so a later real end still advances. `.fileLoaded`
  moves out of the no-op case for this.

No `@Model` change → no migration. Two tests: the reproducing
`forwardStepToEndAdvancesOnceDespiteStaleEof` (red → green), plus a bound-guard test that a
`.fileLoaded` between the step-advance and a later genuine `.endFile(.eof)` lets that real end
advance again (proves the marker doesn't over-suppress).

### F6 `[F]` Pre-V9 images never gain the HDR badge

`ThumbnailService.swift:100`

Image `isHDR` is produced only by a fresh thumbnail render; memory/disk cache hits return
empty `MediaMetadata()` and nothing invalidates existing thumbnails — contradicting the
migration's "repopulates on next display".

Scenario: an existing image playlist upgrades to V9 — rows open with `isHDR = nil`,
`hasCompleteMetadata(.image)` is already true (no `isHDR` gate), the gallery serves cached
thumbnails (memory hit line 100, disk hit in `produceImage`) with empty metadata, so
`imageIsHDR` never runs. HDR images show no badge until the file's size/mtime changes.

Test idea: seed a cached thumbnail + `isHDR = nil` row, request display metadata, assert
`isHDR` gets populated (or decide and document a deliberate re-probe strategy).

#### Fix design (implemented)

Re-triaged and confirmed real. A reproducing test (`diskCacheHitSettlesImageIsHDR`) seeds a disk
thumbnail, drives `thumbnail(for:)` with a record carrying the fingerprint but `isHDR == nil`, and
on the unchanged code observes `result.metadata.isHDR == nil` — the disk-hit served path
(`produceData`, the `!contentChanged && isDecodableImage` branch) reports only size/fingerprint/mtime
and never runs `imageIsHDR`, so an image whose thumbnail predates the `isHDR` column never gains the
badge.

Root cause: `imageIsHDR` is called **only** from a fresh `renderThumbnail` (a disk-cache *miss*).
Every hit path — memory hit and the disk-hit served branch — bypasses it, and `hasCompleteMetadata`
deliberately never gates images on `isHDR` (the decode is slow, so it must stay off the list path).

Fix: settle the image `isHDR` once on the **disk-hit served branch** of `produceData`, gated so the
slow decode runs at most once per image and never off the gallery path:

- Thread the record's current `isHDR` in as `recordIsHDR` (from `thumbnail(for:)` → `produceImage`
  → `produceData`; `thumbnailData`, which has no record, passes `nil`).
- In the served-hit branch, when `!isVideo && isLocal && recordIsHDR == nil`, run `imageIsHDR(at:)`
  and report it in the hit metadata. The `merge` folds it onto the model, which persists it, so a
  later session loads it non-`nil` and the gate skips the probe. Within a session the memory cache
  serves the re-display, so the probe never re-fires. `isLocal` keeps it from reading an evicted
  file; a video settles `isHDR` from colour tags on the list path, so this is images-only.
- This changes no `@Model` and no completeness rule — `isHDR` still doesn't gate image completeness,
  so list mode never probes it and never re-issues.

Tests: `diskCacheHitSettlesImageIsHDR` (RED→GREEN: `isHDR` now `false` for the SDR still instead of
`nil`) and `diskCacheHitSkipsIsHDRProbeWhenAlreadySettled` (a record already carrying `isHDR` gets
`result.metadata.isHDR == nil` back — the probe is skipped, proving the once-only gate; this fails if
the branch probes unconditionally). No true-HDR image fixture exists, so the SDR-settles-`false` path
stands in for the mechanism; the `imageIsHDR` decode itself is the same call the render path already
uses for a real HDR still.

### F7 `[F]` `isHDR` permanently settled false for bitstream-tagged HDR files

`MediaMetadataService.swift:92`

The mpv fallback runs only when duration/dimensions are missing, and the `vo=null` probe
returns before any decode populates `video-params` — so HDR files whose colour tags
AVFoundation can't see get `isHDR = false` settled permanently.

Scenario: HDR10 HEVC mp4 with bitstream-only (VUI) colour tagging and no container `colr`
atom — AVFoundation reads duration+dimensions, `hdrColorTags()` returns nil, line 92 settles
`isHDR = false`; completeness blocks re-examination and the gallery path uses the same tags.
An HDR vp9 webm hits the probe path, which returns at first duration
(`MPVThumbnailer.swift:121`) before decode fills `video-params`/gamma → also settled false.

Test idea: needs a bitstream-only-tagged HDR fixture (may need to be produced with ffmpeg);
assert `isHDR == true` through the list-mode path. If no such fixture is practical, decide
whether the exposure is acceptable and mark `[S]` with rationale.

#### Empirical re-triage (2026-07-24)

Confirmed real, with a sharper root cause than the original hypothesis. Reproduced from a
user report (three real HDR samples in `test_media/videos/` — `HDR10+_Sample_Video.webm`
(vp9), `Awaken AV1 DV Sample.mkv`, `Hybrid HDR10Plus DV Sample.mkv` — never gain the badge
though they play HDR; plus an mkv TV-show folder where a re-scan tags *some* files HDR and
not others, and removing + re-adding the playlist fixes it).

All are `.mkv`/`.webm` → the libmpv fallback probe. `ffprobe` shows the colour tags sit at
the **container/demuxer** level (`color_transfer=smpte2084`) for all three, so no full decode
is needed. An IPC trace of `MPVThumbnailer`'s exact probe config (`vo=null, pause=yes`), one
property per 20 ms poll, on each sample:

```
Hybrid HDR10Plus DV Sample.mkv:  t=0.000  dur=None    demux-w=None  gamma=None
                                 t=0.026  dur=60.06   demux-w=3840  gamma=pq
Awaken AV1 DV Sample.mkv:        t=0.000  dur=None    demux-w=None  gamma=None
                                 t=0.026  dur=60.147  demux-w=3840  gamma=pq
HDR10+_Sample_Video.webm:        t=0.000  dur=None    demux-w=None  gamma=None
                                 t=0.026  dur=12.479  demux-w=1920  gamma=pq
```

`duration`, the demuxer dimensions, and `video-params/gamma` all arrive a few event-loop
turns after `FILE_LOADED`, paused under `vo=null` — no frame needed. Within a single 20 ms
poll they look coincident, but inside mpv the duration is published a hair before the
decoder-side gamma. The probe returned the instant `duration != nil` (old line 121), so on
the tighter samples it captured `gamma == nil` → `MediaMetadataService:92` settled
`isHDR = VideoColorTags.isHDR(nil) == false` permanently; completeness then blocked any
re-probe. The narrow window is why it is racy: `Hybrid` reliably lost it (probe *and* chain
returned gamma `nil`), `Awaken` lost it intermittently (probe `nil` on one call, chain
correct on another), and the webm won it in isolation — the same nondeterminism as the
TV-show folder tagging only some files under scan load. SDR libmpv files publish a non-HDR
gamma (`bt.1886`) just as promptly, so waiting for gamma yields the correct `false` there
too — it does not hang on SDR.

The doc's other scenario — an mp4 whose HDR is signalled *only* in the bitstream VUI with no
container `colr` atom, which AVFoundation opens (so the probe never runs) — is **not** what
these samples hit and is left out of scope here (see Residual below).

#### Fix design (implemented — forward-fix only, per user)

Root cause is the early return, not a missing decode. `MPVThumbnailer.probeMetadata` no
longer returns on `duration` alone when a **video track is present**: it keeps pumping until
the colour tag settles. `refreshMissingFacts` already re-reads `hdrGamma` on every wakeup, so
the loop just keeps spinning until it appears.

- Returns once `duration != nil` **and** (`width == nil` (no video track — audio fallback,
  which never gets gamma) **or** `hdrGamma != nil` **or** a colour-settle grace has elapsed
  since duration became known). The `demux-w`-with-`duration` coincidence above is what makes
  `width == nil` a safe audio marker: it is never *later* than the duration, so a video file
  is never mistaken for audio and returned before its gamma.
- The grace (2s, `colorDeadline`) bounds the pathological "video track but gamma never
  settles" case so a weird file returns quickly (settling `isHDR = false`, as before) instead
  of blocking to the full 15s deadline. Real files pay only the ~26 ms wait, once, off the
  main actor, on first display; the result is cached on the model thereafter.
- Only libmpv-fallback video (`.mkv`/`.webm`) is affected — AVFoundation files get their
  gamma from the moov atom and never enter this probe. The `frame`/`extract` path already
  waits for a decoded PNG (so gamma is present) and is untouched.

No `@Model` change (no migration). No completeness-rule change — an HDR file now settles
`isHDR = true` instead of a wrong `false`, and SDR still settles `false`.

Decision (user chose (a) forward-fix only): existing playlists that already persisted a wrong
`isHDR = false` do **not** self-heal — completeness blocks the re-probe, so those files keep
the wrong badge until the folder is re-added (the known workaround). Matches the project's
"never re-probe" stance; no re-scan/migration heal added.

Residual (mp4 bitstream-VUI-only HDR): not covered by this fix and not reproduced by any
sample on hand; distinguishing "SDR mp4, no tag" from "HDR mp4, VUI-only tag" needs a decode
AVFoundation won't do cheaply. Tracked separately / `[S]` rather than probing every SDR mp4.

Reproduction (RED, uncommitted): the three real samples in `test_media/videos/` are not
git-tracked (nor is that folder) — hundreds of MB of Dolby-Vision video can't live in the
repo — so they are unusable as a committed regression fixture. Run ad hoc against the
unchanged code they gave the RED that confirmed the root cause: `Hybrid` failed both the raw
`MPVThumbnailer.metadata` probe and the `extract` chain, `Awaken` failed the probe — gamma
`nil` → `isHDR false`. All green after the fix.

Test (`HDRProbeTests.swift`, committed): the reproduction can't be committed, so the standing
test is an **end-state guard** over `MediaFixture.hdr` — a 1.8 KB 10-bit VP9 tagged BT.2020
PQ, produced with ffmpeg (`setparams=color_trc=smpte2084`) and bundled in
`ShuTaPlaTests/Fixtures/`. It asserts `isHDR == true` / HDR gamma through both the raw probe
and the `extract` chain, plus an SDR-webm guard (`MediaFixture.vp9`) that still settles
`false`. It deliberately does **not** reproduce the timing race: a fixture small enough to
commit publishes gamma together with the duration (verified — it stays green even against the
pre-fix probe), so it guards the gamma→`isHDR` pipeline, not the wait itself; the wait is
what the ad-hoc heavy-DV reproduction above covers. Adding the fixture also extends
`VideoDurationTests.renderReportsImageAndMetadata` (over `MediaFixture.allCases`) to an HDR
decode. HDRProbeTests (3) + `VideoDurationTests` + `MediaMetadataServiceTests` all green;
navigator clean.

### F8 `[ ]` Truncated-PNG guard removed — corrupt thumbnail can be cached

`MPVThumbnailer.swift:261`

The loop (and the deadline return at line 267) now decode the `vo=image` PNG while mpv may
still be writing it. The removed code returned nil at deadline explicitly "rather than risk
decoding a partial image".

Scenario: `downscaledFrame` runs on every wakeup while the paused instance writes the PNG
non-atomically, and again at deadline while the handle is alive (`terminate_destroy` runs
after the return value is computed). If ImageIO yields an image from an incomplete PNG, the
corrupt frame is HEIC-encoded and cached on disk until the file's size/mtime changes.

Test idea: hard to force the race deterministically — verify by inspection whether a
completeness check (`kCGImageStatusComplete` / decode-after-terminate) restores the guarantee,
and unit-test the guard on a deliberately truncated PNG file.

### F9 `[ ]` `EDRImageLayer` stale scale/EDR across display moves

`EDRImageLayer.swift:31`

`contentsScale` and the EDR opt-in are computed only in `updateNSView`; no
`viewDidChangeBackingProperties`/screen-change response.

Scenario: drag the image player between a 2× and 1× display (or SDR ↔ XDR) — no SwiftUI state
change, `updateNSView` doesn't re-run, the layer keeps the old `contentsScale` (blurry) and
old `preferredDynamicRange` until the user changes image/fit mode. `MPVVideoView` overrides
`viewDidChangeBackingProperties` for exactly this; `BackingLayerView` does not.
`VideoPlaybackEngine.applyColorOutput` (per-file only) shares the EDR-staleness half.

Test idea: view-layer AppKit behavior — verify in-app; unit-test whatever refresh hook is
added if it has a testable seam.

## Efficiency findings

### F10 `[ ]` Duration-less file stalls the thumbnail lane 15 s per display

`MPVThumbnailer.swift:121`

`probeMetadata`/`extract` spin to the full 15 s deadline for a file that loads but never
reports a duration (e.g. an mkv still being written by a recorder; the old code returned at
`FILE_LOADED` with duration nil). `hasCompleteMetadata` stays false, so every display repeats
the 15 s stall on the single serial utility lane, starving all other thumbnail extraction.

### F11 `[ ]` Three sequential AVFoundation loads per file

`ThumbnailService.swift:536` (and `MediaMetadataService.swift:105–108`)

`avAssetFrame`/`avMetadata` await `playableDuration`, `displayPixelSize`, and `hdrColorTags`
strictly sequentially on the same asset; `hdrColorTags` re-issues the `loadTracks` that
`displayPixelSize` already triggered. `async let` on the three loads (or one shared
`load(.tracks)`) does the same work concurrently.

## Convention / doc findings

### F12 `[ ]` Duplicated EDR-capability expression

`EDRImageLayer.swift:28` and `VideoPlaybackEngine.applyColorOutput` (line 53) both contain
`(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1` plus the shared
`window?.screen ?? NSScreen.main` resolution. Fold into one helper (e.g. `NSScreen.supportsEDR`).

### F13 `[ ]` CLAUDE.md still documents the removed `test_media/videos` fixtures

`CLAUDE.md:113` — the testing section still prescribes `test_media/videos/` reached via
`#filePath`, but this branch moved all such tests to bundled `ShuTaPlaTests/Fixtures` via
`MediaFixture` (`ShuTaPlaTests/MediaTestSupport.swift`) and deleted every `#filePath` helper.
Rewrite the section to describe the `MediaFixture` mechanism.

## Deliberately not flagged by the review

- SchemaV9 migration: present, correctly staged, covered by a raw-SQLite test respecting the
  duplicate-model-name trap.
- New engine/client tests follow the empty-file trap-class-3 guidance; suite is `@MainActor`
  (trap class 4).
- Keyframe-granular (not 3 s) hotkey steps: settled decision in
  `doc/tasks/task_20_seek_relative.md`, not a bug. (The review also accepted the coarser
  `absolute+keyframes` scrubber/resume precision under the same rationale — superseded by
  user-reported F14: scrubbing was meant to be exact.)

---

## User-reported (post-review)

### F14 `[F]` Scrubber lands on keyframes, not the pointer position — exact seek expected

`MPVClient.swift:343`

`seek(to:)` issues `absolute+keyframes`, so every absolute seek — the timeline slider
(`PlaybackControlsBar`), the preview drag (`MediaPreviewView`), the audio fraction seeks
(`AudioInlet`/`AudioOverlay`), and the resume restore — lands on the keyframe at or before
the target: up to a full GOP short of where the user pointed. Scrubbing was always meant to
be precise, IINA-style (mpv exact/hr-seek: decode from the previous keyframe to the exact
target). This supersedes the scrubber half of the "settled decision" bullet below; the resume
restore rides along (exact resume is strictly more accurate).

#### Fix design (implemented)

- `seek(to:)` flag: `absolute+keyframes` → `absolute+exact`. Task 20 measured the cost on
  its test clip: ~498 ms exact vs ~255 ms keyframe — the decode from the previous keyframe
  is the price of landing exactly. mpv coalesces the drag's seek stream, so at most one
  exact seek is ever in flight during a drag (same coalescing already documented on
  `stepKeyframe`).
- Keyframe navigation is untouched by design: `stepKeyframe` forward/back and the back-step
  anchor+hop stay `keyframes`; `seek(by:)` (audio skip, `relative`) unchanged.
- F1 machinery is structurally unaffected: an exact seek raises the same
  `MPV_EVENT_SEEK`/`MPV_EVENT_PLAYBACK_RESTART`, and `seekSinceRestart` is set at issuance
  as before. A step merging into an exact scrub still lands at the scrub's target, so the
  parking rationale holds. Comments that reason from the scrub's "keyframe floor" (client
  doc comments, `MPVClientTests` step-landing proof) need rewording: an exact scrub lands
  *at* its target — still never past it, so the step-landing assertion (`position > target`)
  keeps its discriminating power.
- Test first (observed red on current code): real-mpv
  `MPVClientTests/absoluteSeekLandsAtExactTarget`. A WAV cannot discriminate the flag — PCM
  has no keyframes, so even a `keyframes`-flagged seek lands at packet granularity (a WAV
  variant of this test came up green on the unchanged code). The h264 fixture can: 1 s,
  10 fps, a single keyframe at 0.0, so a keyframe-flagged `seek(to: 0.55)` floors to 0.0
  while an exact seek decodes forward to it. Pausing at `fileLoaded` freezes playback, so
  the last observed `time-pos` is the landing; asserted in (0.4, 0.7). Red on keyframes
  ("landed at 0.0"), green on `exact`.

### F15 `[F]` Image pan/zoom: pinch jumps when off-center; zoom-out strands the picture off-viewport

`ImagePlayerView.swift` (`imageLayer`/`zoomGesture`)

User-reported: (1) zoom in → pan → zoom out leaves the image beyond the viewport; (2) with the
image not centered, it "jumps" during pinch zoom. Triage finds three suspects in the gesture
math:

1. **Anchor flip at gesture start.** The committed render is
   `scaleEffect(scale, anchor: .center) + offset`; the live preview is
   `scaleEffect(scale·m, anchor: startAnchor)`. At the first pinch tick (m ≈ 1) with
   `scale ≠ 1`, swapping the anchor from `.center` to `startAnchor` translates the picture by
   `(A − 0.5) · frame · (1 − scale)` in one frame — the off-center jump.
2. **End compensation resolves against the wrong size.** `zoomGesture`'s `onEnded` folds the
   anchor difference into the offset using the *viewport* size, but `scaleEffect`'s
   `UnitPoint` anchor resolves against the *base frame* — the picture's own size in
   `.original` (post-F2: `pixels / displayScale`) — so the committed offset is computed with
   the wrong dimensions there: a second jump at gesture end.
3. **No bounds clamp.** Neither pan nor zoom commits clamp `transform.offset`/`scale` against
   the viewport, so a zoomed-out picture can sit entirely outside it with no way back except
   reset.

#### Fix design (implemented)

Suspects 1–2 are one bug. The current zoom commit —
`offset += (anchor − 0.5)·viewport·(1 − newScale)` — re-expresses to
`O_new = O0 + c·(1 − s_new)` (where `c` is the pinch centre in screen coords and `s_new` the
total new scale). The correct "keep the point under the fingers fixed" commit is

```
s_new = s0 · m                    // m = this gesture's magnification
O_new = m·O0 + (1 − m)·c
```

The two agree only when `s0 = 1` **and** `O0 = 0` — a fresh, centred, un-zoomed image — which
is why the jump appears only once the picture is already zoomed or panned. The correct form is
expressed entirely in screen space (`c` and `O` are both screen-space), so it never involves
the base frame `F`; the viewport-vs-frame distinction in suspect 2 doesn't arise.

Three pure methods on `ImageTransform` (`Engines/ImagePlaybackEngine.swift`), each used in
**both** the live preview and the commit so the two are consistent by construction — no anchor
flip, no reconciliation step:

- `zoomed(by:about:minScale:)` → the correct formula above, with `m = newScale / scale` so the
  min-scale floor stays consistent when it clamps.
- `panned(by:)` → screen-space translate of the offset.
- `clamped(frame:viewport:)` → per axis, bound `|offset| ≤ max(0, (scale·F − V)/2)`. Larger
  than the viewport: pan to the edge, no empty margin. Smaller (zoomed out): the bound is 0, so
  the picture **recenters** — suspect 3, the strand fix.

`ImagePlayerView` then previews with `scaleEffect(_, anchor: .center).offset(_)` over
`transform.zoomed(by: magnifyBy, about: c).panned(by: dragTranslation)`, and each `onEnded`
commits `transform.zoomed(…)`/`transform.panned(…)` then `.clamped(frame:viewport:)`. Clamp is
applied on commit only (no mid-gesture rubber-band). `c = ((startAnchor.x − 0.5)·V.w,
(startAnchor.y − 0.5)·V.h)`.

`ImageTransform` is a plain in-memory struct (reset on image change), not a `@Model`, so no
schema migration. Pan and zoom stay `.simultaneously`; their two `onEnded` commit
independently, so a genuinely concurrent pinch+drag can leave a small `(m − 1)·d` residual
(bounded by the clamp) — accepted, since these input sources rarely blend continuously on macOS
and this is strictly better than the prior behaviour.

`ImageTransformTests` (pure) covers it: the **pinch invariant** — for `s0 ≠ 1` / `O0 ≠ 0`, the
base-local point under `c` (`b = (c − O0)/s0`) must still map to `c` after the commit
(`scale·b + offset == c`), observed red on the ported current math and green after the fix — and
the **clamp** — larger-than-viewport bounds to the edge, smaller-than-viewport recenters to
`.zero`.

### F16 `[F]` Test runs launch the real app — fullscreen resume glitches desktops

`ShuTaPlaApp.swift`

The unit-test target is app-hosted: Xcode launches the real `ShuTaPla.app` as the test host,
so `ShuTaPlaApp.init` opens the real on-disk store, builds the real `AppState`, and the
window resumes player state. Left in fullscreen, the relaunch re-enters fullscreen mid-run —
creating a Space and shuffling the user's desktops. The visible app also shares the main
thread with the `@MainActor` suites, so it looks frozen/broken for the whole run.

#### Fix design (implemented)

`ShuTaPlaApp` derives `isTestHost` from the process environment
(`nonisolated static func isRunningAsTestHost(_:)` reading `XCTestConfigurationFilePath`).
When set, `init` leaves `modelContainer`/`appState` nil and the `WindowGroup` renders a bare
`Color.clear` (no `RootView`, no `.modelContainer`, no `onAppear` wiring); the `Settings`
scene collapses to empty. This kills the fullscreen resume, keeps test runs off the real
library store entirely (previously the host app opened it for real and its quit-time position
persist could write), and removes the frozen real UI. Tests are unaffected — every suite
builds its own in-memory container.

`AppLaunchTests` covers the decision: the pure predicate on a synthetic environment (present
→ true, absent → false) plus `liveProcessIsDetectedAsTestHost`, which asserts the live
`isTestHost` is true during this very run — confirming the env key is actually present and the
guard engages (not just that the predicate is correct).

## Log

- 2026-07-23 — findings recorded from `/code-review xhigh` (single-pass inline run). No
  triage started; implementation awaits per-finding confirmation and user go-ahead.
- 2026-07-23 — F1 confirmed red with
  `PlaybackEngineTests/forwardStepDuringInFlightScrubDoesNotConsumeItsRestart` (test added,
  observed failing on unchanged code for the stated reason). Fix design written into F1;
  implementation awaits confirmation.
- 2026-07-23 — F1 fixed (user-confirmed design). `MPVEvent.playbackRestart` →
  `.forwardStepSettled`; first shipped with `mpv_command_async`-reply landing identification.
- 2026-07-23 — **user-reported regression on the reply variant**: first forward step jumps
  to start / advances; seeks-scrubs sometimes reset position. Root cause: the reply arrives
  before mpv displays the landing frame (and, when the step merges into an in-flight seek, at
  merge time with the optimistic target as position), so frames sampled at the reply read
  flat → the end detector fired on healthy steps. Reworked to parked issuance gated by
  `seekSinceRestart` + sampling at the step's own restart — see the F1 design section for
  the full mechanism and the event-order trace evidence. Green: `PlaybackEngineTests`,
  `MPVClientTests`, `PlaybackCoordinatorTests`, `HotkeyRouterTests`, `MediaPreviewTests`
  (168 total), navigator clean. **Pending: user in-app verification** (mid-file steps step;
  scrub+quick-step doesn't advance; step at end advances; scrubbing behaves).
- 2026-07-23 — **F1 verified in-app by the user** — done. Same report raised F14 (scrub
  must seek exactly, IINA-style, not per keyframe); recorded with proposed design,
  implementation awaits confirmation.
- 2026-07-23 — F14 fixed and verified (user-confirmed design): `seek(to:)` `absolute+keyframes` →
  `absolute+exact`; floor-based comments reworded. Test observed red on the unchanged code
  ("landed at 0.0" on the h264 fixture; a WAV variant proved non-discriminating and was
  replaced), green after the flag flip. All seek-path suites green (`MPVClientTests` 14,
  `PlaybackEngineTests`/`PlaybackCoordinatorTests`/`HotkeyRouterTests`/`MediaPreviewTests`
  155), navigator clean. **Pending: user in-app verification** (scrub lands where pointed;
  drag stays responsive on real videos; steps/end-advance unchanged).
- 2026-07-23 — F2 triaged: the layer renders true 1:1 (pixel per device pixel); only the
  `base()` frame is inflated (pixels-as-points). Fix design written into F2 with a semantics
  choice — (A) pixel-perfect frame `pixels / displayScale` (recommended) vs (B) former
  pixel-dims-as-points via `.resize` gravity; implementation awaits the user's pick.
- 2026-07-23 — F2 fixed (user chose A, pixel-perfect). Frame math extracted to
  `ImageFitMode.baseSize`, test observed red on the extracted current math
  (`HDRImageConfigTests/baseSizeFramesRenderedPicture`: `.original` at scale 2 returned
  full pixel dims), green after dividing by `displayScale`. Surrounding-suite run and
  navigator check pending (interrupted — see F16); then user in-app verification on the 2×
  display: `.original` picture at actual size, pan/zoom hugs the picture, no empty margins.
- 2026-07-23 — F15 recorded (user-reported): pinch-zoom jumps when off-center + zoom-out
  strands the picture off-viewport; triage names three suspects (anchor flip at gesture
  start, end compensation resolving against the viewport instead of the base frame, no
  bounds clamp). Design deferred until F2 is verified in-app.
- 2026-07-23 — F16 recorded (user-reported): app-hosted test runs relaunch the real app,
  which resumes fullscreen and shuffles desktops. Proposed test-host guard in `ShuTaPlaApp`;
  implementation awaits confirmation.
- 2026-07-24 — F2 verified in-app by the user — done. F15 design written and confirmed, then
  fixed: three pure methods on `ImageTransform` (`zoomed(by:about:minScale:)`, `panned(by:)`,
  `clamped(frame:viewport:)`), used in both the live preview and the commit so the render no
  longer flips anchors. `ImagePlayerView` previews and commits through them; clamp on commit.
  `ImageTransformTests` observed red on the ported current commit math (the pinch invariant
  drifted for every `s0 ≠ 1` / `O0 ≠ 0` case — 650/200/92pt — while the from-rest case passed,
  matching the analysis), green after the correct formula. All green (73 across
  `ImageTransformTests` + `HDRImageConfigTests` + `PlaybackCoordinatorTests` + `AppLaunchTests`),
  navigator clean. **Pending: user in-app verification** (off-centre pinch stays put; zoom-out
  recenters instead of stranding; pan stops at the picture edge with no margin).
- 2026-07-24 — F15 in-app feedback: behaves much better; zoom-out below natural size isn't
  useful and shrank too fast. Raised `ImagePlayerView.minScale` 0.1 → 1 (natural size is the
  floor — surface fit in `.fit`/`.cover`, 1:1 in `.original`). Config-only; the floor mechanism
  stays covered by `ImageTransform.zoomed`'s injected-`minScale` test. Build/navigator clean.
- 2026-07-24 — F15 verified in-app by the user (including the natural-size zoom-out floor) — done.
- 2026-07-24 — F16 fixed (user-confirmed design). Test-host guard in `ShuTaPlaApp`
  (`isRunningAsTestHost` / `isTestHost`, both `nonisolated`); `AppLaunchTests` green (3),
  including the live-process assertion that the guard engages in a real hosted run. With it in
  place, F2's interrupted verification completed: `AppLaunchTests` + `HDRImageConfigTests` +
  `PlaybackCoordinatorTests` + `HotkeyRouterTests` + `PlaybackEngineTests` all green (147),
  navigator clean, and the run no longer resumed the app into fullscreen. F2 now needs only
  its user in-app check on the 2× display.
- 2026-07-24 — F3 fixed (user-confirmed design). `pendingBackStep` now cleared in `loadFile`,
  `stop`, `seek(to:)`, and `seek(by:)`. New real-mpv test `armedBackStepDoesNotYankTheNextLoadedFile`
  observed red on the unchanged code (armed back step floored the fresh 0.55 s load to 0.0), green
  after the fix; full `MPVClientTests` green (15), navigator clean. Pending user in-app check.
- 2026-07-24 — F3 verified in-app by the user ("seem to work ok") — done.
- 2026-07-24 — F4 fixed (user-confirmed design). `advanceAfterForwardStep`'s frames signal now
  gated on `framesAtArm > 0`, so a count pinned at 0 (audio-only file in a video playlist, or a
  render context not yet created) no longer reads as a frozen-EOF frame and skips the file. New
  `forwardStepDecision` param case `(arm: 0, settle: 0) → false` observed red on the unchanged
  code (`0 == 0` advanced), green after. The two integration tests that leaned on the same
  conflation were moved off it: `forwardStepWithNoNewVideoFrameAdvances` deleted (its scenario
  is now the no-advance case; unreachable on `vo=null`, which can't produce `arm > 0`),
  `deadForwardStepWithNoSuccessorWrapsToStart` repurposed to drive "dead" via the position
  signal (`settled == origin`). Full `PlaybackEngineTests` green (34), navigator clean. Pending
  user in-app check.
- 2026-07-24 — F5 fixed (user-confirmed design). Re-triaged against the post-F1
  `.forwardStepSettled` code and confirmed real: the reproducing
  `forwardStepToEndAdvancesOnceDespiteStaleEof` (settled-first `forwardStepSettled(50, frames:1)`
  then `endFile(.eof)`) went red on the unchanged handler with `advancedTo == [b, c]` — the
  settled path clears `forwardStep`, leaving the unconditional eof handler to advance a second
  time. Fix adds a one-shot `forwardStepReachedEnd`: the settled handler sets it only on a real
  advance to a distinct successor (not the wrap-to-start), `.endFile(.eof)` consumes-and-returns
  when set, and `.fileLoaded` (moved out of the no-op case) clears it — the bound for the
  last-keyframe case where mpv never flips `eof-reached` so no stale eof comes. Bound-guard test
  `genuineEofAfterForwardStepAdvanceStillAdvances` proves a `.fileLoaded` between the step-advance
  and a later genuine eof still advances (no over-suppression). Full `PlaybackEngineTests` green
  (36), navigator clean. No `@Model` change → no migration. Pending user in-app check.
- 2026-07-24 — F6 fixed (user-confirmed design). Confirmed real: `diskCacheHitSettlesImageIsHDR`
  (seed disk thumbnail, drive `thumbnail(for:)` with fingerprint set + `isHDR == nil`) went red on
  the unchanged code with `result.metadata.isHDR == nil` — the disk-hit served path reported only
  size/fingerprint/mtime and never ran `imageIsHDR`, so a pre-`isHDR` image never gained the badge.
  Fix threads the record's `isHDR` in as `recordIsHDR` (`thumbnail(for:)` → `produceImage` →
  `produceData`; `thumbnailData` passes `nil`) and, on the disk-hit served branch, probes
  `imageIsHDR` once when `!isVideo && isLocal && recordIsHDR == nil`, reporting it in the hit
  metadata. So the slow decode runs at most once per image (merge persists it → next session skips;
  memory cache serves same-session re-displays), never off the gallery path, never on an evicted
  file. Guard test `diskCacheHitSkipsIsHDRProbeWhenAlreadySettled` proves an already-settled record
  gets `isHDR == nil` back (fails if the branch probes unconditionally). Full `ThumbnailServiceTests`
  green (26), navigator clean. No `@Model` change and no completeness-rule change → list mode still
  never probes, so nothing re-issues. Pending user in-app check.
