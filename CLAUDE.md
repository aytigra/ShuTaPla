# ShuTaPla

macOS media player. SwiftUI(macOS 26+) + SwiftData + mpv (libmpv).

## **IMPORTANT!!!**: These rules are always in force during planning and implementation process

**Everything in this file governs every task and every *process* — including when you are executing a slash command, running inside a skill, or driving subagents.**

**The work is organized through plan files in doc/tasks folder. A design or implementation decision is settled only once it has been talked through with the user and written into the task doc file. Task steps are established in such file and always implemented only one step at a time.** Anything that lives only in the running context — above all a compaction summary(which can drift) — is provisional.

**Load relevant skills before implementation**

**Ensure test coverage and confirmation/refutal tests before changing code. Always review freshly written tests to prevent traps that interrupt work**

**During the whole implementation process re-check your work against the task doc, not only against the code in front of you.** If agreed goal and surrounding code pull apart, or any uncertainty arises, notice it and resolve it deliberately rather than letting proximity decide, stop and ask if resolution is not obvious.

**When changing SwiftData models - add migration**

**When inferred implementation does not work after several tries - stop guessing, do documentation and web search!**

**Before concluding task/step as done run a checklist**

- does issue navigator has standing issues?
- does it follow code conventions?
- can code be simplified and deduplicated?
- does it adhere to writing rules?

## Key docs

- `doc/features.md` — feature-spec entry point: overview, Terminology glossary, and a map of the per-topic chapters in `doc/features/` (load only the chapter you need)
- `doc/architecture.md` — system design and architecture

## Writing rules

**Describe the code as it is now — no residue, no change-narration.** Artifacts (docs, plans, comments, commit messages) should describe the current code statically, as if it had always been this way. Two facets of one rule: (1) never describe a dismissed alternative or a corrected/replaced choice; (2) even when nothing was rejected, don't narrate continuity or evolution relative to some earlier state. Mention a former state only when the current choice is genuinely hard to understand without it, and then only as an explanation of the current choice.

This governs *descriptions of the code* and main documentation. It does not apply to work-tracking artifacts in `doc/tasks/`.

## Code conventions

Should be applied meaningfully without overdoing.

**Less code is the default; simplify the whole, not just the part you add.** Code is a liability — fewer lines, fewer concepts, and less duplication is very important! Whenever you add to existing code or refactor it, step back and look at the result as a whole: can naming be made consistent, can duplicated logic be folded together, can the new and the old collapse into something smaller and more coherent? Strive to do this as part of the change, not only as a later cleanup — debt compounds fast when every change only adds. 

**Modularity and helpers**

A type extension in `Extensions/` is a good fit for a general operation on a standard type (e.g. an Array) — but it is one tool among other (inlining, a shared function, or a new type, helper functions), not something to apply everywhere by reflex. Splitting a large file into modules or partials is important!

**Don't stack a `count: 1` and `count: 2` tap gesture on the same view.** SwiftUI can't fire the single-tap handler until the system double-click interval elapses. Use one `onTapGesture` and branch on the underlying event's click count instead.

**`HotkeyRouter` owns bare keyboard input, not the responder chain.** Its app-wide `NSEvent` monitor intercepts keys before any SwiftUI `.alert`, so a modal's own button shortcuts never fire and bare keys leak to whatever the router routes them to. Present confirmations as `.alert` (with `.defaultAction`/`.cancelAction` buttons that handle `[enter]`/`[esc]` natively) and register the modal's `AppState` flag in the router's `hasBlockingConfirmation`.

## Claude Code configuration

This project uses `~/.claude-ios/` as the Claude Code configuration directory (not the default `~/.claude/`). MCP servers, skills, settings, and memory are all stored there.

## MCP servers

**Xcode MCP** (`xcode`) is available. It provides direct access to the running Xcode instance via `mcpbridge` — use it to build the project, run tests, read/write files through Xcode, search documentation, list navigator issues, and render SwiftUI previews. Prefer Xcode MCP tools over raw `xcodebuild` commands when Xcode is running.

## Skills

Locally installed skills live in `/Users/aytm/.claude-ios/skills/`.

**Loading the matching skill is mandatory, and it is the first step — before you start reading or changing the code, not after.**

| Skill | Path | Load when the work touches |
|-------|------|---------|
| **swiftui-expert-skill** | `skills/swiftui-expert-skill/` | State management (`@Observable`, `@MainActor`, `@Environment`), Observation tracking, view composition, performance patterns, ForEach identity, LazyVStack/LazyVGrid, animations, accessibility, Liquid Glass (iOS 26+) — and any SwiftData-backed view reactivity |
| **swift-concurrency** | `skills/swift-concurrency/` | async/await, actors, Sendable, AsyncStream, Task groups, Swift 6 migration, data race safety, `Mutex` |
| **swift-testing-expert** | `skills/swift-testing-expert/` | Swift Testing framework (`@Test`, `#expect`, `#require`), parameterized tests, traits/tags, async testing, XCTest migration |
| **mobile-ios-design** | `skills/mobile-ios-design/` | HIG principles, SF Symbols, Dynamic Type, navigation patterns, layout, dark mode, accessibility |

Each skill has a `SKILL.md` with workflow decision trees and a `references/` directory with detailed topic guides. Read the SKILL.md first, then drill into references as needed.

## Testing

**Tests are first-class and lead the work, not trail it.** Write the test before the change it covers, and run it to watch it behave as expected:

**"Test first" means test the *current* code first — it's a verb, not a file you create.** The point is empirical: before you change anything, you *run* a test and observe how the code behaves as it stands. Writing a `@Test` and not running it is the ritual without the substance. An unrun test proves nothing — it can be green with the bug still present (wrong path exercised, wrong assertion), so it never validated itself as a test. Worse, when the change is driven by a *suspected* bug (a code-review finding, a hunch, a "this looks wrong"), the finding is a **hypothesis**, not a fact — and running the test against the unchanged code is the experiment that confirms or refutes it. If it comes up green on the current code, the bug doesn't reproduce: the finding was a false positive and you must **not** change the code — you'd be mutating correct code and rubber-stamping it with a test that never demonstrated a problem. So: observe the failure *before* writing the fix, always, one change at a time. If you haven't run anything against the unchanged code, you haven't started — and you cannot call a fix done, or even "written, pending a run," on the strength of a test you've never executed.
- **Fixing a bug:** write a failing test that reproduces it *first*, run it against the unchanged code, and confirm it fails *for the stated reason* (not merely that it's red). Only then fix the code and watch it pass. A green test on the original code means the bug isn't there — refute the finding and leave the code alone. A bug fixed without a reproducing test that was observed to go red-then-green is not done.
- **Refactoring:** make sure the behavior, the underlying code of it - everything that will be directly or indirectly touched by refactor, is covered by passing tests *before* you start, so the refactor is verified to preserve it. Add the missing coverage first if it isn't there.
- **New feature:** cover the testable logic as you build it, not as a follow-up. Prefer testing the stateless/pure core (helpers, services with injectable seams) where a view layer makes direct unit testing impractical.

Treat "where is the test?" as part of the definition of done — don't report a change complete without it.

**Check the issue navigator before reporting done.** A build can succeed while the compiler still flags warnings (deprecations, unused values, concurrency issues) that won't surface unless you look. After the work builds, list navigator issues (`mcp__xcode__XcodeListNavigatorIssues`) and address — or surface to the user — any warnings the change introduced. This is part of the definition of done alongside tests.

**Avoid test traps — they hang the run, not just the test.** A test that hits `EXC_BREAKPOINT` (code=1) or `EXC_BAD_ACCESS` doesn't fail cleanly: it crashes the test host mid-run, so the run never returns a result and the build/test tool (and the agent driving it) stalls. Treat "could this trap?" as a first-class concern when writing tests. The trap classes seen so far, and how to write around each:

1. **Orphaned `ModelContext` → `EXC_BREAKPOINT` on the next `fetch`.** Hold the `ModelContainer` for the whole test body, pulling `container.mainContext` locally — as `ModelTests.swift` does. A helper that builds a container internally and returns only `container.mainContext` lets the container deallocate when the helper returns; the orphaned context traps on its next `fetch` — surfacing at the fetch site, e.g. `AppStateModel.fetchOrCreate` (which `AppState.init` calls, so even constructing `AppState` traps). Plain `init`-and-assert tests trap most reliably; tests with intervening `insert(...)` or `await` may survive by chance because they stretch the autorelease pool, so the failure can look intermittent.

2. **Async work that outlives the in-memory container → `Fatal error: This model instance was destroyed by calling ModelContext.reset`.** A fire-and-forget `Task` that touches SwiftData models keeps running after the test body returns; the container then tears down and the task dereferences a freed (temporary-id) model, trapping mid-run. Triggers: `AppState.select(_:)` launches an un-awaited re-scan `updateTask`; an engine reaching natural EOF calls `advanceToNext()` which walks `playlist.playbackSequence`; the slideshow timer. Write around it — set state directly instead of via the task-launching path (e.g. `appState.selectedPlaylist = x; appState.recomputeFilteredFiles()` rather than `select(x)`), or `await appState.updateTask?.value` before the body ends, and always `defer { coordinator.shutdown() }`.

3. **Real libmpv engine teardown race → `EXC_BAD_ACCESS` in `mpv_wait_event`.** A wakeup-scheduled event drain can land on the serial queue after `mpv_terminate_destroy` (now gated by `MPVClient.isTerminated`). Keep tests on the safe side: use the window-free `AudioPlaybackEngine` (`vo=null`) for any mpv channel — never `VideoPlaybackEngine` in the test host (it needs a GL surface); always `defer { shutdown() }`; and back fixtures with **empty** placeholder files. Empty files fail to load (`END_FILE` reason `error`, not natural EOF), so they never trigger an `advanceToNext()` that would touch models after teardown — that's why `PlaybackCoordinatorTests`/`HotkeyRouterTests` write `Data()` files.

When a routing/logic test only needs the coordinator's synchronous bookkeeping, prefer an **image** playlist (the image engine has no libmpv) over a video/audio one to avoid trap class 3 entirely.

4. **Closure that captures `inout self` in a `mutating` extension → `EXC_BREAKPOINT` from `dispatch_assert_queue_fail`.** The target builds with `-enable-upcoming-feature NonisolatedNonsendingByDefault`, so a closure passed to `.map`/`.filter`/etc. inside a `mutating` extension method inherits the caller's actor isolation. When the closure runs, `swift_task_isCurrentExecutorWithFlagsImpl` calls `dispatch_assert_queue` against the inherited executor and traps if the current queue doesn't match. Production call sites (e.g. `@MainActor AppState.reorder` → `[Playlist].move(...)`) reach the closure from the main queue and pass the check; a Swift Testing `@Test` on a plain (non-`@MainActor`) suite runs on the cooperative queue and traps. `Array.move(fromOffsets:toOffset:)` in `Extensions/Array+Move.swift` collects with a `for index in source { moved.append(self[index]) }` loop for this reason — don't capture `self` in a closure body inside any `mutating` extension on a value type. If a suite that exercises one of these helpers must keep a closure form, annotate it `@MainActor` so the queue check holds.

**Real video samples for media tests live in `test_media/videos/` (repo root, not in a target).** Filenames carry the codec: `h264*.mp4`, `h265:hevc.mp4`, `mpeg-*.mpeg` (AVFoundation-decodable) and `vp8*.webm`, `vp9*.webm` (libmpv-only — the `MPVThumbnailer` fallback path). Tests reach them relative to `#filePath` (two levels up from `ShuTaPlaTests/` is the repo root), matching by prefix to stay robust to the bracketed tag suffixes and `(N)` variants in some names. These exercise the stateless extraction helpers (`ThumbnailService.renderThumbnail`, `MPVThumbnailer.frame`/`.duration`), which create and synchronously tear down their own short-lived mpv handles — no wakeup-scheduled drain, so trap class 3 doesn't apply.

## Xcode project structure

This project uses Xcode **file system synchronized groups** (`PBXFileSystemSynchronizedRootGroup`). The following directories auto-sync with Xcode — files created on disk inside them appear in the Xcode project navigator automatically:

- `ShuTaPla/` — app source
- `ShuTaPlaTests/` — unit tests
- `ShuTaPlaUITests/` — UI tests
- `doc/` — documentation

**Always create new files inside one of these directories.** Files created outside them (e.g., at the project root) will NOT appear in Xcode unless manually added to `project.pbxproj`.
