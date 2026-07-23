# Task 20 — Relative video seek (hotkey / preview ±3s)

The skip hotkey (`[right option]+[arrow]` in the player, `[arrow]` in the Manager preview) should
move the video **once** to the adjacent keyframe — the next keyframe forward, the previous one back —
without a visible double jump, without a freeze, and without sailing past the end of the file.

## Problem

A single ±3s press on a **video** moves the progress bar **twice** — first to the requested
position, then a second jump to a keyframe — so one press travels far more than 3s (a ~1-minute
clip is crossed in ~6 presses). Near the end the second jump lands past EOF: the video freezes there
while audio keeps seeking correctly. Audio-only seeks are always a clean single 3s.

Both surfaces funnel through one method: `MPVPlaybackEngine.seek(by:)` (`MPVPlaybackEngine.swift:165`)
→ `MPVClient.seek(by:)`.

## Root cause (measured)

libmpv's default for a **relative** seek is *inexact keyframe* seeking. Instrumented `time-pos`
event capture on real media (`.audio`/`vo=null`; position events fire regardless of video output) —
frozen at 6.400s, keyframes at 6/9/12 (3s GOP), a +3 press:

| seek command | `time-pos` events (bar draws these) | final landing | speed (HDR clip) |
|---|---|---|---|
| `relative` (= `relative+keyframes`) | 9.400 → **12.000** | keyframe *after* target (**overshoot +5.6**) | 485 ms |
| `relative+exact` | 9.400 | exact 9.400 | 498 ms |
| `absolute+keyframes` (target 9.4) | 9.400 → **9.000** | keyframe *at/before* target (floor) | **255 ms** |
| `absolute+exact` | 9.400 | exact 9.400 | 498 ms |

Three facts this establishes:

1. **The double jump is universal to inexact seeks.** mpv reports the *requested* number instantly
   (optimistic `time-pos`), then corrects to the real keyframe once playback restarts. Our progress
   binding draws both. `exact` shows no double only because its landing equals the target.
2. **Relative keyframe seeks correct to the keyframe *past* the target** → the overshoot, and the
   EOF freeze (near the end the internal target exceeds duration).
3. **Absolute keyframe seeks correct to the keyframe *at/before* the target** (floor) → they never
   overshoot (so no EOF freeze) and are the *fastest* of all — a keyframe lands with no decode.

## Rejected approaches (measured / confirmed in-app)

- **`relative+exact` / any exact seek.** Precise but decode-bound: it stutters on small clips and
  hangs up to ~1s on 4k/HDR — confirmed in-app on the real video path, where hardware decoding *is*
  active (`hwdec=auto-safe`, mpv logs `Using hardware decoding (videotoolbox)`). So the cost is the
  decode from the previous keyframe to the target, not a missing hwdec. IINA hides this with an
  adaptive per-file mode (measures the first exact seek; keeps `relative+exact` only while it stays
  under ~50 ms, else falls back to keyframe) — more machinery than this feature needs.
- **`absolute+keyframes` to a computed, half-step-biased target.** The floor snaps to the keyframe
  *at or before* the target, so on files whose GOP is larger than the step it lands back on the
  keyframe already playing — no progress, "restarts on the same keyframe." A fixed half-step bias
  can't cross a multi-second GOP, so it can't rescue long-GOP HDR clips.
- **mpv's plain relative keyframe seek by the full ±delta.** Moves *at least* the delta, so it ceils
  to the keyframe *past* the target — overshoots by up to a GOP, and near the end ceils past the last
  decodable frame and freezes the video while audio keeps seeking.

## Fix — step to the adjacent keyframe

mpv has no dedicated "next/previous keyframe" command; the way to get one is a **relative
`keyframes` seek**, which restarts playback at a keyframe boundary. But mpv rounds a relative
keyframe seek *toward the direction of travel*, and the two directions are not symmetric — this was
confirmed in-app: forward stepped cleanly, backward stuck on the current keyframe until 2–3 presses
happened to cross it.

- **Forward** → `seek +ε relative+keyframes` (ε small, ~0.1 s). mpv rounds *up* to the keyframe at
  or after the target, so a tiny ε lands on the **next** keyframe. One seek.
- **Backward** → mpv rounds *down* to the keyframe at or before the target, so `−ε` floors right
  back onto the keyframe already playing (the current GOP's start), not the previous one. Reaching
  the previous keyframe needs **two hops**: anchor on the current GOP's keyframe
  (`absolute+keyframes` at the live position), then seek just before it (`absolute+keyframes` at
  `anchor − ε`). The second hop is deferred until the anchor settles (signalled by mpv's
  `PLAYBACK_RESTART` event) because mpv **coalesces back-to-back seeks** — a seek queued behind a
  pending one merges into it, collapsing both onto the same keyframe and defeating the two-hop.

Neither direction can overshoot (a keyframe is the closest real landing) or stall, so the
no-progress and freeze failure modes above are structurally gone. Trade-offs, accepted with the
user: steps are **keyframe-granular (~one GOP)**, not a fixed number of seconds; and a backward
press produces **two keyframe restarts** (a brief flash through the anchor, and a doubled audio
click — the click is a separate follow-up).

**End of file — pending in-app confirmation.** A forward step taken in the *last* GOP has no next
keyframe. Whatever mpv does there (stays put, or freezes as the old relative seek did), the engine
should detect it — a forward press whose settled position did not advance, or a video that stops
progressing while audio continues — and call `advanceToNext()`: in the player its successor is the
next file (switch), in the preview its successor is itself (restart from 0). This reactively covers
the end without predicting keyframe positions, but the exact detection depends on how mpv behaves at
the last GOP, which the in-app test of the step behavior reveals — so it is built after that test.

## Integration seams (ShuTaPla)

- `MPVClient` keeps two keyframe primitives, no exact/slow path anywhere: `seek(to:)`
  (`absolute+keyframes`, the scrubber) and `stepKeyframe(forward:)` (the hotkey — one relative seek
  forward, a `PLAYBACK_RESTART`-gated two-hop backward via `completeBackStepIfPending()`).
  `keyframeStepEpsilon` holds ε; `pendingBackStep` carries the deferred second hop across the drain.
- The keyframe step is **video-only**: audio has no keyframes, so a keyframe "step" degenerates
  into the ±ε hop. `MPVClient.Configuration.keyframeStepping` fixes the skip mode per channel
  (video `true`, audio `false`); `MPVPlaybackEngine.seek(by:)` either uses only the delta's sign
  and calls `client.stepKeyframe` (video), or seeks by the full signed delta via `client.seek(by:)`
  (`relative` — audio's always-clean path, which also never arms end-of-file detection;
  `eof-reached` covers audio's end).
- `Configuration.audioOutput` can be `.null` (`ao=null`): silent, no audio hardware — the test
  configurations (`silentAudio` / `silentKeyframeStepping` in `MediaTestSupport.swift`) use it so
  test runs are inaudible; `silentKeyframeStepping` also lets tests drive the keyframe-step logic
  without a GL surface.
- Both hotkey surfaces already share `MPVPlaybackEngine.seek(by:)` (player:
  `PlaybackCoordinator+Controls.swift`; preview: `MediaPreview.swift`), so the change is one
  chokepoint.

## Decisions (settled with user)

- **Primitive:** step to the adjacent keyframe via a tiny `relative+keyframes` seek — not exact, not
  a computed absolute target, not a full-delta relative seek.
- **Speed over precision:** keyframe (instant, no decode). Exact is rejected — confirmed slow in-app
  even with hardware decoding, because the cost is the keyframe→target decode.
- **Keyframe-granular steps, not a fixed 3 s:** the step size is one GOP; in exchange there is no
  overshoot, no freeze, and no per-file guessing.
- **End of file reactively → `advanceToNext()`:** a forward step that can't advance (or freezes)
  switches file in the player and restarts in the preview.

## Steps (implement one at a time, after confirmation)

1. **Adjacent-keyframe step — done.** `MPVClient.stepKeyframe(forward:)` steps one keyframe:
   forward a single `relative+keyframes` seek; backward a `PLAYBACK_RESTART`-gated two-hop (anchor
   on the current keyframe, then seek just before it) since mpv can't undershoot to the previous
   keyframe in one move. `MPVPlaybackEngine.seek(by:)` maps the hotkey's sign to it **on the video
   channel only** (`Configuration.keyframeStepping`): the audio channel keeps the full-delta
   `relative` seek (`MPVClient.seek(by:)`), since keyframe-less audio would otherwise "step" by the
   ε only — caught by user after the first cut routed audio through the keyframe step too
   (`audioEngineSeeksByTheFullDelta` reproduces it red→green). The removed
   absolute-target/bias math took `SeekTargetTests` with it (it asserted that math). No headless
   media test is added: the behavior lives in mpv's keyframe/coalescing semantics and event timing,
   which need real playback (the video engine needs a GL surface, forbidden in the test host), so it
   is validated in-app — keeping flaky media tests out.
2. **End-of-file detection → advance — done.** In-app, a
   forward step in the last GOP is file-dependent: some files flip `eof-reached` (already handled —
   natural advance), others stick on the last keyframe or freeze the video with no EOF signal.
   Detection, in two layers:
   - **No forward progress (primary) — done.** A mid-file forward step always lands on the *next*
     keyframe (strictly ahead — forward keyframe seeks round up), so a forward step whose
     **settled** position is not ahead of where it started can only mean there is no next keyframe:
     the end. Wiring as built: `MPVEvent.playbackRestart(TimeInterval)` — the client reads the
     settled `time-pos` synchronously at `PLAYBACK_RESTART`, *before* running
     `completeBackStepIfPending` (whose second hop moves the position again). The engine arms
     `forwardStepOrigin` in `seek(by:)` on a forward press; every other load/seek/stop disarms it so
     an unrelated restart can't masquerade as the step's landing. On `.playbackRestart` the armed
     origin is consumed and the pure decision `advanceAfterForwardStep(from:to:) -> Bool`
     (`settled <= origin`) picks advance or nothing. No duration-margin guessing.
     Tests: the decision is parameterized media-free; the arming/disarming wiring is driven through
     `engine.handle(_:)` (`PlaybackEngineTests`); the client's settled-position read is proven
     against a real seek (`MPVClientTests/settledSeekEmitsPlaybackRestartAtItsPosition`) — backed by
     a generated WAV (`writeTempWAV` in `MediaTestSupport.swift`), because the lavfi virtual sources
     are **not seekable** (a `seek` on them errors and settles nothing). The two pre-existing seek
     tests (`seekMovesTimePosition`, `seekMovesTime`) had only ever passed by playing to ~9s in real
     time; both now use the WAV with timeouts shorter than the seek target, so only a real seek can
     pass them (they settle in ~0.2–0.4s).
   - **No new video frame (layer 2) — wired and confirmed in-app.** Layer 1 was
     confirmed in-app to miss a third variant, measured on a Dolby-Vision mkv (60.1s, ~10s GOPs,
     last video keyframe ~51.4, audio runs to 60.1): a forward step past the last video keyframe
     puts the **video track** in EOF (mpv logs `video EOF reached`, picture frozen) while **audio
     seeks fine and keeps playing** — the restart settles ~ε *ahead* of the origin (the clock also
     runs between arm and execute), so layer 1 reads it as progress on every press, and
     `eof-reached` never flips because audio hasn't ended. Position arithmetic cannot catch this:
     any threshold on `settled − origin` would false-advance on all-intra files, where a healthy
     step also moves only ~ε.
     mpv exposes no per-track EOF signal (input.rst, master: no `video-pts`; `track-list/N/*` has
     no playback status; `demuxer-cache-state/eof` is the whole reader thread and marked
     unstable). The one trustworthy "video produced a frame" signal is the **render-update
     callback**: a healthy step always shows its landing frame before the restart completes
     (`first video frame after restart shown`), the frozen restart completes with `video=eof` and
     none. Design: `MPVClient` counts render updates (`Mutex<UInt64>` — the callback fires on an
     mpv-internal thread); `.playbackRestart` carries the count read at the restart alongside the
     settled position; the engine snapshots the count when arming. Advance if **either** signal
     fires: `settled <= origin` (layer 1 — catches stick-on-last-keyframe, where the re-shown
     frame may re-fire the callback) or the count didn't move (layer 2 — catches frozen video,
     where the position always advances). `vo=null` clients never increment the counter, but
     never arm either (audio's `keyframeStepping=false`); tests drive `handle(_:)` with explicit
     counts. **Counter verified in-app before wiring** on two freezing files and one that
     advances via layer 1: healthy steps render their landing frame (count +1/+2 across the
     step), every frozen restart is flat; stray +1 redraws occur while frozen but landed
     *between* presses — if one ever lands inside an arm→settle window that press is merely
     missed (no advance; the next press is flat), never a spurious advance. Wiring: the count
     snapshot is armed alongside the origin; `advanceAfterForwardStep(from:to:framesAtArm:framesAtSettle:)`
     ORs the two signals. Tests: the frozen scenario red→green
     (`forwardStepWithNoNewVideoFrameAdvances`), the decision parameterized over both axes
     (including the all-intra ~ε step that must *not* advance), prior wiring tests carry frame
     values isolating which signal decides.

   **In-app confirmed (player); preview wrap decided.** In the player, a forward press in the last
   GOP of the freezing files now switches file. In the preview the same press logs
   `decision advance` but nothing visibly happens: `MediaPreview.fileAfter` returns `nil` (a peek
   is one file), so `advanceToNext()` returns `false` and holds — the frozen frame stays with
   audio running on until the *audio* ends (the frozen class never raises whole-file EOF early, so
   the preview's `loop-file=inf` wrap only comes at the audio's natural end — up to the rest of
   the track late). The log also confirmed the frame counter's predicted shape in the wild: stray
   redraws while frozen land *between* presses (arm counts climbed 173→174→175), the count flat
   across every arm→settle window.
   Decided with user: when the advance decision fires but `advanceToNext()` has nowhere to go
   (returns `false` — the preview's nil successor, or a one-file sequence whose successor is
   itself), the engine **wraps to the start** (`seek(to: 0)`), so a forward press at the end never
   leaves playback stuck. `seek(to:)` sets `currentTime` optimistically (the pattern `startFile`
   already uses; mpv corrects via `time-pos`), which is also the wrap's test observable.

   **In-app confirmed:** player advance on the freezing files, preview wrap-to-start on a dead
   forward press, no spurious advance in normal use. The `stepEOF:` instrumentation prints are
   removed. **Step 2 done.**

## Testable

- Adjacent-keyframe step (in-app): forward moves to the next keyframe, backward to the previous, one
  step per press, no overshoot, on SDR + Dolby-Vision clips.
- End of file (unit + in-app): `advanceAfterForwardStep(from:to:)` returns advance when the settled
  position didn't move ahead of the origin, step otherwise; in-app, a forward press with no next
  keyframe switches file (player) / restarts (preview) instead of sticking.
