# Fullscreen fails after a panel opens during the transition

A system panel that opens while the Player window enters fullscreen breaks fullscreen for the rest of the session.

Status: **not started.**

## Problem

- Repro (running app): press `[m]` in Player during the fullscreen transition. The folder chooser opens, the transition fails, and the Player stays windowed for the session.
- `FullscreenController` (`Extensions/NSWindow+Fullscreen.swift`) holds the window's fullscreen state. The cause is not known. Other panels or sheets that open during the transition (the add-playlist chooser) are not checked.

## Steps

1. **Cause.** Reproduce on the running app and find the state that stays wrong after the failed transition. Check whether a panel or sheet during the exit transition has the same result. Record the cause here, and ask before choosing a fix.
2. **Fix.** Test first on the unchanged code where the cause has a testable seam; else verify on the running app. Fix, then update `doc/features/players.md` if the fix changes what the user sees.
