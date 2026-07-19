# Profiling

How to record and read an Instruments trace for Shutapla. It is a macOS app, so the **host Mac is
the profiling device** and the **SwiftUI** template works directly (no simulator caveat).

Tooling lives in the `swiftui-expert-skill`:
`~/.claude-ios/skills/swiftui-expert-skill/scripts/record_trace.py` (record) and
`analyze_trace.py` (parse). Load that skill for the full reference.

## Fixture

Profile the Xcode **Debug** build (bundle id `com.aytigra.Shutapla.debug`) — it has its own on-disk
store, separate from the `/Applications` release build, so it can carry realistic test data.

## Recording an interaction (warm path)

Captures anything you drive by hand — selection, switching, scrolling, edits.

1. Launch **exactly one** instance and grab its pid:
   ```bash
   APP=~/Library/Developer/Xcode/DerivedData/ShuTaPla-*/Build/Products/Debug/Shutapla.app
   open -n $APP
   pgrep -f "Build/Products/Debug/Shutapla.app/Contents/MacOS/ShuTaPla"   # → one pid
   ```
2. Attach the recorder (background it with a stop-file so you can end it cleanly):
   ```bash
   python3 "$SKILL/scripts/record_trace.py" \
     --template SwiftUI --attach <pid> \
     --stop-file /tmp/stop-trace --output <dir>/session.trace
   ```
3. Exercise the app.
4. `touch /tmp/stop-trace` — the recorder SIGINTs xctrace and finalises.

### Traps — read before recording

- **Never use `--launch` on `Shutapla.app`.** `xctrace` resolves the launch target by the bundle's
  basename, and there are two `Shutapla.app` on the machine (`/Applications` + DerivedData) → it
  aborts with *"process is ambiguous"*. Use `open -n` + `--attach <pid>` instead.
- **Never profile a copied bundle.** A copy keeps the same bundle id, so LaunchServices opens *two*
  instances against one store.
- **Don't press Run in Xcode during a capture** — that's a second instance on the same store.
- **One store, one process.** Two instances on the same SwiftData store contend on the SQLite lock
  and distort exactly the fetch timings you're measuring. Confirm a single pid before recording.

## Recording a cold launch

`--attach` can't see startup. To profile launch / first-frame cost, quit every instance, start a
system-wide recording, then launch:
```bash
python3 "$SKILL/scripts/record_trace.py" --template SwiftUI --all-processes \
  --stop-file /tmp/stop-trace --output <dir>/launch.trace &
open -n $APP        # cold start is now captured
touch /tmp/stop-trace   # a few seconds after the window settles
```

## Reading a trace

```bash
python3 "$SKILL/scripts/analyze_trace.py" --trace <t> --json-only --top 12
```
- **Hangs lane + `correlations`** — each main-thread hang with `main_running_coverage_pct` (100% =
  fully CPU-bound on main) and its hot symbols. This is where user-perceived lag lives.
- **`swiftui-causes`** — what keeps invalidating views. On the **host Mac this lane sometimes comes
  back empty**; fall back to inferring view churn from `AG::Graph::*` and refcount symbols in the
  time-profiler.
- **Sizing a subsystem below the top-N floor.** A subsystem can be real cost yet have every
  individual symbol rank below `--top 12`. Dump the full table and sum it before concluding it's
  negligible:
  ```bash
  python3 "$SKILL/scripts/analyze_trace.py" --trace <t> --json-only --top 5000 > full.json
  # then grep+sum a subsystem's symbols (e.g. every sqlite3*/CoreData symbol) for its real weight
  ```

## Where traces go

Save trace bundles under `profiling/` — it's **gitignored** (a `.trace` is a large binary, machine-
and run-specific). Keep the *conclusions* in the relevant `doc/tasks/` file, not the raw trace.
