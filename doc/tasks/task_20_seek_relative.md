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
2. **End-of-file detection → advance — layer 1 done, in-app confirmation pending.** In-app, a
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
   - **Freeze watchdog (assess after).** If a step can still leave the video frozen *past* the start
     (settled ahead but frames not advancing), layer 1 misses it and a `time-pos`-stall watchdog
     would be needed. Deferred until layer 1 is tested in-app and we see whether freeze still occurs
     — a timer here is a test-trap risk, so it isn't added speculatively.

   One call covers both surfaces, with a correction to what was written above: in the **preview**,
   `MediaPreview.fileAfter` returns `nil` and `SourceNavigating.advanceToNext()` *holds* when there
   is no distinct successor — it does **not** reload/restart. So a preview forward step at the end
   is a benign no-op; the preview's `loop-file=inf` wraps to 0 on its own (a seek past the end
   raises EOF, which loop-file restarts). Whether that wrap feels right — or the preview needs an
   explicit restart-from-0 on a dead forward step — is part of the in-app confirmation.

   **In-app checks remaining:** on the stick-on-last-keyframe files, a forward press in the last
   GOP switches file in the player; no spurious advance on normal steps/scrubs/back-steps; preview
   behavior at the end; whether any freeze case survives (→ watchdog decision).

## Testable

- Adjacent-keyframe step (in-app): forward moves to the next keyframe, backward to the previous, one
  step per press, no overshoot, on SDR + Dolby-Vision clips.
- End of file (unit + in-app): `advanceAfterForwardStep(from:to:)` returns advance when the settled
  position didn't move ahead of the origin, step otherwise; in-app, a forward press with no next
  keyframe switches file (player) / restarts (preview) instead of sticking.
