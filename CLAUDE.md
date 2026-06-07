# ShuTaPla

macOS media player. SwiftUI + SwiftData + mpv (libmpv).

## Key docs

- `doc/features.md` — complete feature specification
- `doc/architecture.md` — system design and architecture (17 sections)

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

## Xcode project structure

This project uses Xcode **file system synchronized groups** (`PBXFileSystemSynchronizedRootGroup`). The following directories auto-sync with Xcode — files created on disk inside them appear in the Xcode project navigator automatically:

- `ShuTaPla/` — app source
- `ShuTaPlaTests/` — unit tests
- `ShuTaPlaUITests/` — UI tests
- `doc/` — documentation

**Always create new files inside one of these directories.** Files created outside them (e.g., at the project root) will NOT appear in Xcode unless manually added to `project.pbxproj`.

After creating files from the CLI, switch focus to Xcode so its filesystem watcher picks up the changes.
