# Test-suite audit (task)

Standalone audit, processed separately from the background-scan-derivation work. Sweep
the test suite for tests that pass without actually exercising the behavior they claim,
and fix or remove them.

## Why

The tag-filter fix surfaced several tests that were green for the wrong reasons —
fixtures that can't exist in production, and assertions that ran against state the test
hadn't actually produced yet. Three such fixtures were corrected in passing
(`tagFilterAppliesAndOrCorrectly`, `serviceFilterOverridesAndRestoresTagFilter`,
`switchingPlaylistsRestoresPersistedFilter` — filenames that didn't carry the tags the
file was seeded with). A systematic sweep should find the rest.

## What to look for

1. **Inconsistent fixtures.** `addFile(name, tags:)` / `ScannedFile(...)` /
   `insertFile(...)` where `name` does not parse (via `TagParser.fields(for:)`) to the
   tags or `taggingStatus` the file is seeded with — e.g. a file named `"a.mp4"` seeded
   `tags: ["beach"]`, or named `"c.mp4"` seeded `.invalid`. This is now a real
   correctness gap: the scan derives tags from the filename, so such a file's seeded
   tags are not what production would ever hold, and the test asserts against impossible
   data. A valid tagged fixture names the file for its tags (`"a [beach].mp4"`); an
   invalid one uses a filename that genuinely parses invalid (a too-short token like
   `"c [ab].mp4"`, or two bracket groups).

2. **Assert-before-await false greens.** Assertions that run before an in-flight
   `Task`/`updateTask` is awaited, so they observe the pre-async state, not the behavior
   named in the test. These pass deterministically (the MainActor task can't interleave
   before the first `await`), which makes them look intentional — but they are testing
   the setup, not the outcome. Either await the work first, or assert on the pre-async
   state explicitly and name it as such.

3. **Assertions that cannot fail.** `Set`-comparisons broad enough to hold regardless of
   the behavior, `isEmpty` on a collection that was never populated, `#expect(x == x)`
   shapes, or a `#expect` whose subject the test never mutates.

4. **Mismatched derived state after a scan.** With derivation now part of the scan, a
   test that manages/rescans a playlist and then asserts on tags/`taggingStatus` must
   seed filenames consistent with those tags, or await the scan and assert the derived
   result — not the seeded one.

## Approach

- Grep the test targets for the fixture builders (`addFile`, `insertFile`, `scanned`,
  `ScannedFile(`) and cross-check each `name` against its seeded `tags`/`status`.
- For each suspect, run it, then mutate the production code it claims to cover (or the
  fixture) to confirm the test actually goes red when the behavior breaks. A test that
  stays green when the behavior is broken is the target.
- Fix by correcting the fixture or the await ordering; delete only if the test is
  genuinely redundant. Keep the suite's intent — most of these are real tests with bad
  fixtures, not useless tests.

## Out of scope

The fixture corrections already shipped with the tag-filter fix are done; this task is
the remaining sweep.
