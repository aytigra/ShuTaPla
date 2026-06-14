# ShuTaPla

macOS media player. SwiftUI + SwiftData + mpv (libmpv).

## Key docs

- `doc/features.md` — complete feature specification
- `doc/architecture.md` — system design and architecture

## Writing rules

**No residue from dismissed alternatives.** When a choice, code, or prose is corrected or replaced, never describe the dismissed version in artifacts (docs, plans, comments, commit messages) — no "it is no longer X", "this does not do Y anymore", "unlike before". Mention the former state only when the current choice is hard to understand without it, and only as an explanation of the current choice.

## Code conventions

**Extract reusable logic into type extensions.** When a piece of logic is a general operation on a standard type (e.g. an array reordering that mirrors SwiftUI's `move(fromOffsets:toOffset:)`), add it as a type extension in `Extensions/` rather than inlining the body at the call site — even when the motivation is to avoid an import (e.g. SwiftUI in the state layer). Keeps call sites readable, makes the helper reusable and testable on its own, and matches familiar standard-library/SwiftUI naming.

## Claude Code configuration

This project uses `~/.claude-ios/` as the Claude Code configuration directory (not the default `~/.claude/`). MCP servers, skills, settings, and memory are all stored there.

## MCP servers

**Xcode MCP** (`xcode`) is available. It provides direct access to the running Xcode instance via `mcpbridge` — use it to build the project, run tests, read/write files through Xcode, search documentation, list navigator issues, and render SwiftUI previews. Prefer Xcode MCP tools over raw `xcodebuild` commands when Xcode is running.

## Skills

Locally installed skills live in `/Users/aytm/.claude-ios/skills/`. Use them for implementation guidance and code review.

| Skill | Path | Use for |
|-------|------|---------|
| **swiftui-expert-skill** | `skills/swiftui-expert-skill/` | State management (`@Observable`, `@MainActor`, `@Environment`), view composition, performance patterns, ForEach identity, LazyVStack, animations, accessibility, Liquid Glass (iOS 26+) |
| **swift-concurrency** | `skills/swift-concurrency/` | async/await, actors, Sendable, AsyncStream, Task groups, Swift 6 migration, data race safety, `Mutex` |
| **swift-testing-expert** | `skills/swift-testing-expert/` | Swift Testing framework (`@Test`, `#expect`, `#require`), parameterized tests, traits/tags, async testing, XCTest migration |
| **mobile-ios-design** | `skills/mobile-ios-design/` | HIG principles, SF Symbols, Dynamic Type, navigation patterns, layout, dark mode, accessibility |

Each skill has a `SKILL.md` with workflow decision trees and a `references/` directory with detailed topic guides. Read the SKILL.md first, then drill into references as needed.

## Testing

**Avoid test traps — they hang the run, not just the test.** A test that hits `EXC_BREAKPOINT` (code=1) or `EXC_BAD_ACCESS` doesn't fail cleanly: it crashes the test host mid-run, so the run never returns a result and the build/test tool (and the agent driving it) stalls. Treat "could this trap?" as a first-class concern when writing tests. The three trap classes seen so far, and how to write around each:

1. **Orphaned `ModelContext` → `EXC_BREAKPOINT` on the next `fetch`.** Hold the `ModelContainer` for the whole test body, pulling `container.mainContext` locally — as `ModelTests.swift` does. A helper that builds a container internally and returns only `container.mainContext` lets the container deallocate when the helper returns; the orphaned context traps on its next `fetch` — surfacing at the fetch site, e.g. `AppStateModel.fetchOrCreate` (which `AppState.init` calls, so even constructing `AppState` traps). Plain `init`-and-assert tests trap most reliably; tests with intervening `insert(...)` or `await` may survive by chance because they stretch the autorelease pool, so the failure can look intermittent.

2. **Async work that outlives the in-memory container → `Fatal error: This model instance was destroyed by calling ModelContext.reset`.** A fire-and-forget `Task` that touches SwiftData models keeps running after the test body returns; the container then tears down and the task dereferences a freed (temporary-id) model, trapping mid-run. Triggers: `AppState.select(_:)` launches an un-awaited re-scan `updateTask`; an engine reaching natural EOF calls `advanceToNext()` which walks `playlist.playbackSequence`; the slideshow timer. Write around it — set state directly instead of via the task-launching path (e.g. `appState.selectedPlaylist = x; appState.recomputeFilteredFiles()` rather than `select(x)`), or `await appState.updateTask?.value` before the body ends, and always `defer { coordinator.shutdown() }`.

3. **Real libmpv engine teardown race → `EXC_BAD_ACCESS` in `mpv_wait_event`.** A wakeup-scheduled event drain can land on the serial queue after `mpv_terminate_destroy` (now gated by `MPVClient.isTerminated`). Keep tests on the safe side: use the window-free `AudioPlaybackEngine` (`vo=null`) for any mpv channel — never `VideoPlaybackEngine` in the test host (it needs a GL surface); always `defer { shutdown() }`; and back fixtures with **empty** placeholder files. Empty files fail to load (`END_FILE` reason `error`, not natural EOF), so they never trigger an `advanceToNext()` that would touch models after teardown — that's why `PlaybackCoordinatorTests`/`HotkeyRouterTests` write `Data()` files.

When a routing/logic test only needs the coordinator's synchronous bookkeeping, prefer an **image** playlist (the image engine has no libmpv) over a video/audio one to avoid trap class 3 entirely.

## Xcode project structure

This project uses Xcode **file system synchronized groups** (`PBXFileSystemSynchronizedRootGroup`). The following directories auto-sync with Xcode — files created on disk inside them appear in the Xcode project navigator automatically:

- `ShuTaPla/` — app source
- `ShuTaPlaTests/` — unit tests
- `ShuTaPlaUITests/` — UI tests
- `doc/` — documentation

**Always create new files inside one of these directories.** Files created outside them (e.g., at the project root) will NOT appear in Xcode unless manually added to `project.pbxproj`.

After creating files from the CLI, switch focus to Xcode so its filesystem watcher picks up the changes.
