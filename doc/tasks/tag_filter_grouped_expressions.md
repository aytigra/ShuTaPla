# Task — Four-field tag filter

A playlist's tag filter is **four independent tag lists**, AND-joined, one per combination of
polarity and quantifier. The match mode is not a control — it is *which list the tag was typed
into*. A file matches when all four hold; an empty list is vacuously true.

| Field | Matches |
|---|---|
| Must have all | file carries every tag in the list |
| Must have any | file carries at least one of them |
| Must not have all | file is missing at least one of them (dropped only when it has every one) |
| Must not have any | file carries none of them |

Several lists can be filled at once: `A AND B AND (C OR D)` is must-have-all `[A, B]` +
must-have-any `[C, D]`. A tag may repeat across lists, redundantly or contradictorily (`A` in
must-have-all and must-not-have-any matches nothing); nothing prevents or warns about it.

A **top-level OR** — `(A AND B) OR (C AND D)` — stays out of scope: it needs a real expression
builder, which is the bulk of the work.

Status: all seven steps done (2b+3 landed together, carrying step 4's predicate port with them; step 4
then pointed the coverage at it). Verified after step 6: 929 tests, the only two failures the standing
`PlaybackEngineTests` load flakes (both green in isolation, and green here before the change), and the
navigator holds no warning from this work — only the standing `ThumbnailServiceTests` QoS inversion and
the project's "recommended settings" notice. Step 7 touched documentation only.

Follow-up, done after step 7: `setTagFilter(_:in:on:)` — the whole-list setter with no production
caller left — is dropped, and with it the private `editFilter(on:_:)` it shared with
`toggleFilterTag`, now that the toggle is the only caller. The tests that used the setter to seed a
filter go through the toggle instead; the one test written *about* the setter is re-aimed at what
survives it (fields are independent, only the last token dropped takes the row). Emptying a list is
no longer reachable except one token at a time, so the row-delete branch no longer has to guard
against a never-inserted fresh row — the guard came out with a comment saying why it is safe.

Also done after step 7: the duplicate-save refusal is registered as blocking. The reported symptom
was `[esc]` not dismissing it — the router doesn't merely fail to swallow keys for an unregistered
modal, it *consumes* `[esc]` itself (Manager's idle-esc chain), so the alert never saw it. Confirmed
before changing anything by the two standing router tests: `managerEscIsConsumedButLeavesWindowOpenWhenIdle`
(unregistered ⇒ esc consumed) and `errorAlertHoldsKeyboardContext` (registered ⇒ esc passed through).

The fix generalizes the channel rather than adding an eighth flag. `ConfirmationError` →
`ErrorNotice`, `confirmationError` → `errorNotice`: one app-wide titled OK-alert channel, hosted in
`RootView`, for anything that failed or was refused. `saveCurrentSearch` now raises the refusal on it
instead of returning a `String?` for the view to hold, and the two "Tag change failed" alerts —
`PlaylistTagsView`'s and `TagEditorView`'s, the same view-local defect, found while looking — go
through it too. Three `.alert` hosts and three `@State` strings gone (the tag editor's mattered
most: it is mounted in three places, each of which was carrying its own copy); the router still
checks one flag for all of them.

The remaining four flags in `hasBlockingConfirmation` (`playerRenameError`, `audioRenameError`,
`addPlaylistError`, `saveError`) are the same shape and could fold in as well — not done, since each
is a live channel with its own tests and none of them is broken.

## Model

The four lists and the saved searches over them are store rows, not a Codable value embedded in
both: `captureResumePosition` fires from `setCurrentFile` on every file switch, and against rows it
is a one-column `setIfChanged` write instead of re-encoding a whole JSON list; and a named saved
search wants its own identity and store-side ordering.

```swift
/// A key over `TagFilter`'s four lists, not stored state. Everything that acts on all four
/// (rewrite, drop, the AppState edits, the grid) iterates `allCases` and subscripts.
nonisolated enum TagFilterField: String, Sendable, CaseIterable {
    case mustHaveAll, mustHaveAny, mustNotHaveAll, mustNotHaveAny

    /// Field label above the token field, and the lead-in of the generated summary.
    var label: String { "Must have all" / "Must have any" / "Must not have all" / "Must not have any" }
}

@Model final class TagFilter {
    // User-entered order, kept for display.
    var mustHaveAll: [String] = []
    var mustHaveAny: [String] = []
    var mustNotHaveAll: [String] = []
    var mustNotHaveAny: [String] = []

    /// The playlist applying this filter right now — nil on a saved search's filter while some
    /// other filter is live.
    var playlist: Playlist?

    /// The name and resume position saved over these lists; nil ⇒ ad-hoc filter.
    @Relationship(deleteRule: .cascade, inverse: \SavedSearch.filter) var savedSearch: SavedSearch?

    // Computed, not stored:
    subscript(field: TagFilterField) -> [String] { get set }   // switches over the four lists
    var isEmpty: Bool { get }                                  // every list empty
}

@Model final class SavedSearch {
    /// Non-optional with a default, so no display site nil-coalesces. Several searches may share it;
    /// the generated summary on the row's second line is what tells them apart.
    var name: String = "Unnamed search"
    var listOrder: Int = 0
    var resumeSortOrder: Int?
    @Relationship(deleteRule: .cascade) var filter: TagFilter?
    var playlist: Playlist?
}
```

On `Playlist` — replacing `filterState` and the `[SavedSearch]` blob:

```swift
@Relationship(deleteRule: .cascade, inverse: \TagFilter.playlist) var currentFilter: TagFilter?

/// Unordered, as every SwiftData to-many is, so every read site sorts by `listOrder`. That order is
/// stable insertion order, not most-recently-used — applying a search never reorders the list under
/// the user; only the explicit reorder control rewrites it.
@Relationship(deleteRule: .cascade, inverse: \SavedSearch.playlist) var savedSearches: [SavedSearch] = []

/// The service filter's `rawValue`. Stored as a string rather than the enum so an unrecognized
/// value — a triage case removed in a later version — reads back as "no filter" instead of failing
/// the attribute's decode, which is the leniency `FilterState` decoded by hand.
var serviceFilterRaw: String?
var serviceFilter: ServiceFilter? { get set }   // computed: ServiceFilter(rawValue:)

var unfilteredResumeSortOrder: Int?   // unchanged
```

### Ownership and lifecycle

A playlist owns its filters; a filter and the search saved over it **cascade both ways**, because
neither means anything alone. That makes "an emptied filter is deleted, and its search goes too" a
single `delete(filter)` with nothing to branch on — the cascade terminates by itself, the second
delete landing on an already-deleted row.

A playlist reaches its filters two ways: `currentFilter` for the one applied now, and
`savedSearches` → `filter` for the rest. Being applied is not ownership, so moving `currentFilter`
is safe — delete rules fire on delete, never on reassignment.

**A `TagFilter` with neither `playlist` nor `savedSearch` set is unreachable and must never exist.**
That is the invariant the rules below keep, and it is worth its own test.

**Write-through.** Applying a saved search points `currentFilter` at the search's own `TagFilter`
row, not a copy, so editing the filter edits the search — there is no commit step. Which search is
active is `currentFilter?.savedSearch`; `nil` *is* what "ad-hoc filter" means.

**Creation.** Adding a token to any field of a playlist whose `currentFilter` is nil inserts a
`TagFilter` and attaches it. There is no other way a filter row appears — a saved search is always
saved *over* one that exists.

Teardown is four rules, and only the first branches:

- **Replacing the current filter** (Clear, or applying another search) deletes the outgoing
  `TagFilter` only when it is ad-hoc; a filter a search was saved over is left alone. This lives in
  the one method that assigns `currentFilter`.
- **Emptying all four lists** — by hand, or because a playlist-wide tag removal took the last tag —
  is `delete(filter)`, taking any `SavedSearch` with it and leaving the playlist unfiltered. An
  active saved search dies here unconfirmed while `Clear` would have kept it: intended, since the
  name described a combination that no longer exists, and a search over no lists matches everything
  and is not worth a dropdown entry.
- **`Delete saved search`** (the confirmed button in the expanded strip) is the same call from the
  other end: `delete(search)` takes the filter, so deleting the active search leaves the playlist
  unfiltered rather than keeping its tags as an ad-hoc filter.
- **Deleting a playlist** needs no handling — its two cascades reach every pair.

**Enabling a service filter is not teardown.** It leaves `currentFilter` untouched, exactly as today,
so a tag filter set underneath survives the trip and comes back when the service filter is cleared —
an ad-hoc filter is never destroyed by a detour through triage. The two are therefore *storable*
together, and it is the strip that resolves them by precedence (below), not the model. Only the
reverse direction writes: setting a tag filter — the `PlaylistTagsView` row tap, or any token added
in the strip — nils `serviceFilterRaw`, the side effect that already exists.

**Resume slots.** `activeResumeSortOrder` / `captureResumePosition` read the relationship directly;
the `ResumeSlot` enum is deleted, since it only carried an index into the old array:

```swift
guard serviceFilter == nil else { return nil }           // service filters earn no slot
guard let filter = currentFilter else { return unfilteredResumeSortOrder }
return filter.savedSearch?.resumeSortOrder               // nil ⇒ ad-hoc, no slot
```

The first guard is what makes a service filter answer **no slot** rather than inheriting whatever the
tag filter underneath would answer — the search's slot when one is set, the unfiltered slot when none
is. Those are three different answers and only the guard separates them, so it needs a test of its
own (a service filter over a set tag filter, and over none) to keep a later simplification pass from
folding it away.

`unfilteredResumeSortOrder` restores the position when a saved search is cleared mid-session. An
ad-hoc filter needs no slot: you never switch *into* ad-hoc, and on relaunch the playlist's
`currentFileID` resumes it. `clearResumePositions` (Reshuffle) nils `unfilteredResumeSortOrder` and
walks the `savedSearches` rows.

**Duplicate saved searches** are refused when `Save` is pressed, not gated on — `saveCurrentSearch`
returns `String?` like `renameFile`/`addTag`, naming the search that already covers the combination,
and the strip alerts as `PlaylistTagsView` does. The comparison (normalized, order-insensitive per
field, against every saved search) runs once per press and never in a `body`, so
`isCurrentFilterSaved` does not survive as a property. Write-through means two searches can still be
edited into agreement; that is accepted rather than paid for on every token edit.

**Tag rewrite / drop** (`Playlist+Filtering`) maps every list of `currentFilter` and of each saved
search's filter over `TagFilterField.allCases`. A search is discarded only when the removal leaves
all four lists empty — the same rule as above, no separate threshold.

## Evaluation — small predicates, composed at runtime

Each **filled** field contributes one flat subquery over `file.tags`, AND-joined with the scope and
with the other filled fields — sibling subqueries, not the nested-subquery-over-a-captured-array shape
that traps (CLAUDE.md trap 6). Every field collapses to the same count-against-a-threshold comparison,
so there is no per-field branching:

```swift
// Names are lowercased and deduped per field; every threshold counts the *deduped* names, so a
// tag typed twice (or in two casings) can't make must-have-all unsatisfiable:
//   haveAll → count >= haveAllNames.count
//   haveAny → count >= 1
//   notAll  → count <  notAllNames.count
//   notAny  → count <  1
```

The four are **not** one `#Predicate`: one `#Predicate` holds at most two `file.tags.filter { … }.count`
subqueries, or three conjuncts, before the type-checker gives up with *"unable to type-check this
expression in reasonable time"*. The limit is the macro's expansion — a single deeply nested generic
expression — not SwiftData and not SQLite, and it is about the whole expression's complexity rather
than subqueries as such: four `.evaluate` calls with no subquery among them fail the same way.

So each field is its own small `Predicate<PlaylistFile>`, nested into the others with `.evaluate(_:)`
(the macro lowers it to `build_evaluate`) and folded **pairwise** so no single expansion grows large.
Three small free functions cover everything: `fieldPredicate(_:names:)` picks the field's two numbers,
`countPredicate(names:threshold:atLeast:)` is the one subquery shape, and `andPredicate(_:_:)` joins a
pair. Runtime nesting depth is unconstrained — the ceiling is a source-level type-checking limit, so a
depth-four fold costs nothing to compile.

Because the clauses are uniformly typed values built at runtime, **only the filled fields are built at
all** — `filter.filledFields.reduce(scope) { andPredicate($0, fieldPredicate(…)) }`. An empty field
contributes no subquery rather than a vacuously-true one, so there are no `skip…` guards to reason
about, and an all-empty filter *is* the scalar predicate: `sequencePredicate` needs no separate fast
path, because composing one is the fast path. Measured at **1.00x** carrying no filter row at all,
over 2000 tagged rows.

SwiftData translates the nested node to SQL, so the fetch stays one store-side query returning
identifiers. Measured over a 2000-file playlist carrying 47 distinct tags (2 per file): a four-field
combination costs **1.68x** a flat one-subquery `#Predicate` known to translate (1.51 ms vs 0.90 ms
per `sequence(of:)`), where an in-memory fallback materializing every row and its tag rows would be
orders of magnitude worse. The same test derives its expected count from an independent pass in Swift
over the same rows, so a wrong translation fails rather than being timed as if correct.
`TagFilterPredicateTests` drives the shipped query layer — a `TagFilter` attached to a playlist, read
back through `sequence(of:)` — and pins the four rules, the AND-join, the all-four composition, the
contradictory case, the dedupe thresholds and the `atOrAfter` bound against a real store.

The cost is that the pairwise fold looks arbitrary without knowing the ceiling, and that SwiftData's
support for a nested predicate is undocumented — the cost test is what would catch a regression.

The store still filters, sorts and returns identifiers only, so `atOrAfter` + `fetchLimit: 1`
(`resumeTarget`), `fetchCount` (`sequenceNotEmpty`) and the `PlaybackSequences` memo are untouched.
The service filter selects the predicate in Swift as it does now.

## Schema — `SchemaV10`

Two new entities (`TagFilter`, `SavedSearch`) and a reshaped `Playlist`: `filterState` removed,
`savedSearches` from stored blob to relationship, `serviceFilterRaw` and the two new relationships
added.

**No data is carried across** — filters are cheap to re-enter — so the stage drops the old columns
rather than deriving rows, which makes it `.lightweight`. The open question — whether inference
accepts `savedSearches` changing from composite attribute to relationship **under the same name** —
is answered yes: the migration test opens a V9 store carrying a filter blob and two saved searches
and it migrates clean, so the fallback rename to `searches` was not needed.

Two traps specific to this change:

- **`SchemaV5`–`V8`'s pinned `Playlist` copies reference the live `FilterState`, `SavedSearch` and
  `FilterMode`.** All three must be pinned before the live types change — that is what makes step 3's
  deletions safe. Editing the live types instead would retroactively change frozen entity hashes.
- **`SchemaV9` references live types**, so it needs its own pinned set before it can be this stage's
  "from" version. Pinning it swaps the app's live models out (`ShuTaPlaApp` builds its container from
  `SchemaV9`), so it only works paired with V10 — hence both in 2b.
- **`SchemaV10` cannot be registered before the live models change.** A version is only a name for
  whatever its `models` declare, so a V10 added ahead of the reshaping is byte-identical to V9, and
  `AppMigrationPlan` then throws `NSInvalidArgumentException: Duplicate version checksums detected.`
  — an uncaught ObjC exception that aborts the process (in the test host, mid-run). This is what makes
  2b's "with step 3" a hard requirement rather than a preference: the pinning, the version and the
  model change are one landing. Written up in `doc/versioning.md`.

Per CLAUDE.md trap 5 the migration test keeps at most two same-named `@Model` types — pinned V9 plus
live — and asserts through raw SQLite (`indexDDL` / `columns` / `rowCount`) as the existing cases do.

## UI — one strip, collapsed by default

Four labelled token fields is too tall to sit open permanently, and named saved searches too wide for
an inline list, so the filter collapses into the **service-filter strip** — the single home for
everything that narrows a playlist. One component, mounted where `PlaylistCenterView`'s `noticeBar`
is in Manager and at the top of the file column in the overlays, replacing both `FilterBar` mounts
(`TagSidebar`, `LibrarySurface`) and the service-filter notices. The tag sidebar is left as tag
*editing* only; the cache banner stays above the strip.

**Collapsed:** `[ › Filter ] [ Searches ] [ …service-filter notices… ]`

- `› Filter` expands the strip in place; the caret shows the state.
- `Searches` opens a dropdown as wide as the center area. Each row is the search's name over its
  generated summary, with up/down buttons rewriting `listOrder` and a remove button.
- **The two buttons say what is set**, so the strip needn't be expanded to answer "filtered, by
  what": an ad-hoc filter tints `Filter`; a saved search replaces the `Searches` label with its name.
  Both, and `Clear`, are absent when nothing is set.

A tag filter and a service filter can both be set at once (the model keeps them independent, so the
tag filter survives a detour through triage), so the strip resolves them by **precedence** — one
total ordering, each case showing exactly one thing:

1. **A review mode** (duplicates, skipped) — its banner alone. Mutually exclusive with filtering,
   which is why `filterChanged` already calls `exitReviewModes()`.
2. **A service filter** — its "Showing …" state and clear affordance alone; `Filter`, `Searches`,
   `Clear` and the notices are all hidden. This matches what the store does: `sequencePredicate`
   already prefers the service filter over the tag filter.
3. **A set tag filter** — `Filter` / `Searches` / `Clear`, with the notices hidden.
4. **Nothing set** — `Filter` / `Searches` / the notices.

A tag filter parked under case 2 is hidden, not lost: the service filter always carries its clear
affordance, and clearing it drops straight to case 3 with the filter intact. That is the whole reason
the model does not clear one when the other is set.

`PlaylistTagsView` sits outside this ordering — its row tap sets a one-tag filter and is reachable
from the toolbar under any case. So the **"editing a tag clears the service filter" side effect
stays** on that path; without it the tap would land on a filter case 2 is hiding, and look like
nothing happened.

**Expanded** (in place, not a dropdown): the four token fields in a responsive grid — one, two or
four columns by width, each labelled above — plus the name, save/delete button and `Clear` when a
filter is set. Collapses on a Filter click. Expansion is plain view state on the strip — not
persisted, not per playlist — so each mount (Manager, the two overlays) keeps its own.

**At most one completion dropdown is open at a time:** focusing another field unfocuses the previous
one, which closes it. So the grid needs no fixed row-order `zIndex` — only the *focused* field is
raised above its siblings.

**The generated summary** names the fields: `Must have all: A, B · Must have any: C, D`. Empty fields
are omitted; all four empty never occurs.

**Naming lives in the expanded strip**, where the user can see what is set, and doubles as the
saved/ad-hoc indicator:

- `currentFilter?.savedSearch == nil` — name field empty, button reads `Save`; pressing it creates
  the search (typed name, or `Unnamed search`) over the existing row, or refuses as a duplicate.
- A saved search is active — name field bound to its name, edits landing directly like the tag lists.
  The button becomes `Delete saved search` (confirmed), the only action left once updates are
  implicit.

So the Searches dropdown does picking and ordering only.

**Player mode** shows the same strip **without the triage counts at all** — no notices, no toggles.
An active service filter still shows its "Showing …" state and clear button, since it can be entered
from the Manager and must be escapable from the player.

Two build notes. The delete confirmation is an `.alert` whose flag joins `hasBlockingConfirmation`
(`HotkeyRouter.swift:141`) — `HotkeyRouter`'s app-wide `NSEvent` monitor takes bare keys before the
responder chain, so a modal's own shortcuts never fire otherwise. The Searches dropdown floats over
the file list, so it needs the `zIndex` treatment both `FilterBar` mounts already use.

**No `esc`-to-collapse binding**: the caret is the only control. Expansion is view state, and the
router's monitor eats bare keys before the responder chain, so `esc` could only be reached through an
`AppState` seam — not worth a second control for a one-click toggle.

## Steps

Implemented one at a time, each with its tests run before the change it covers.

Steps 3–6 tear out `filterState` at the model end and put the new lists back at the view end. Left
alone that leaves `FilterBar`, `TagSidebar`, `LibrarySurface` and `PlaylistCenterView` on properties
that no longer exist, so the target would not compile across steps 4 and 5 — and with no build there
is no running the tests *before* each change, which is the whole method. **So step 3 carries a shim:**
`FilterBar` drops to a placeholder that edits nothing, and `PlaylistCenterView`'s service notices are
rewired to `serviceFilterRaw` (a few lines step 6 keeps anyway). Every step then builds and the suite
runs throughout, and `SchemaV10` is settled once in 2b rather than revised at the end.

The alternative — keeping `filterState` and the old types until their last user goes — was rejected:
it compiles, but from step 4 on the view layer writes one filter representation while the query layer
reads the other, so the build is green and the app silently unfiltered. A visibly inert placeholder
is the honest state.

1. ✅ **Prove the predicate shape** — `ShuTaPlaTests/TagFilterPredicateTests.swift` (6 tests) and
   `ShuTaPlaTests/TagFilterCascadeProbeTests.swift` (5 tests), all green.

   Findings, all empirical:
   - **Sibling subqueries evaluate fine** — the four rules, the AND-join, the deduped thresholds and
     the `atOrAfter` bound all match store-side over seeded tags. No `NSInvalidArgumentException`;
     CLAUDE.md trap 6 is about the *nested* shape only, as expected.
   - **A single `#Predicate` cannot hold the four fields** — the ceiling is two `file.tags` subqueries
     or three conjuncts, and it is expression complexity rather than subqueries as such: four
     `.evaluate` calls with no subquery among them fail identically.
   - **Nesting small predicates with `.evaluate(_:)` clears it, and SwiftData runs the result as SQL**
     — a four-field combination over 2000 files / 47 tags costs 1.55x a flat one-subquery `#Predicate`,
     not the orders of magnitude an in-memory fallback would cost. See *Evaluation* above; step 4 is a
     mechanical port of the proven builder.
   - **No guards and no fast path** — composing only the filled fields makes an empty field contribute
     nothing, so an all-empty filter is the scalar predicate itself, measured 0.99x.
   - **The mutual cascade works as designed** — `delete(filter)` reaps the search, `delete(search)`
     reaps the filter and leaves the owner's reference nil, deleting the owner converges both
     cascades on the same two rows without orphan or trap, and reassigning the applied filter fires
     no delete rule. No fallback needed.

   Disposition of the two probes: the predicate one **stays** — it becomes step 4's test against the
   real models. The ad-hoc cascade models are throwaway and go once step 3's cascade tests cover the
   real pair.
2. **Schema groundwork**, in two parts because `SchemaV10` cannot name types that do not exist yet:
   - **2a.** ✅ Pinned `FilterState`, `SavedSearch` and `FilterMode` into `SchemaV5`–`V8` as
     `LegacyFilter.State` / `.SavedSearch` / `.Mode` — one shared set, since the shape never moved
     across those versions, carrying stored members only.

     The check the step was written with — the existing migration tests — turned out not to be one:
     they write *and* read with the pinned copies, so a shifted hash moves both sides together and
     they stay green (verified: a deliberate member rename left all four passing). So the guard is
     `SchemaVersionHashTests`, which freezes each version's entity hashes as CoreData records them in
     `Z_METADATA` — the number an existing store is actually placed by. Captured from the unchanged
     code, then held across the change; the same deliberate rename turns V5–V8 red on the `Playlist`
     hash and leaves V9 green. Nesting the copies costs nothing: the hash covers a composite's member
     names and types, not the type's own name. Written up in `doc/versioning.md`.
   - **2b.** ✅ Landed **with step 3, as one change** — not a preference but a constraint (the third
     Schema trap above). `SchemaV9`'s Playlist/PlaylistFile/Tag are pinned copies over
     `LegacyFilter`; `SchemaV10` names the live models plus `TagFilter`/`SavedSearch`;
     `AppMigrationPlan` gained the version, the `.lightweight` V9→V10 stage and a header paragraph;
     `ShuTaPlaApp` builds from V10.

     Two things the run settled, both by observation rather than inference:
     - **The pinned V9 is faithful.** V5–V9's recorded entity hashes are byte-identical to their
       goldens with V9 pinned and the plan live, so stores in the field still place correctly. V10's
       own hashes are now frozen too — `PlaylistFile` is unchanged there and it is `Playlist` that
       moves, the mirror of the V5/V6 case.
     - **The stage carries a real V9 store.** `migratingAV9StoreReplacesTheFilterBlobWithRows` writes
       a filter blob, two saved searches, files and tags at pinned V9, reopens through the plan, and
       asserts from SQLite: `ZTAGFILTER`/`ZSAVEDSEARCH` exist, `ZSERVICEFILTERRAW` was added,
       `ZFILTERSTATE` is gone, files/tags/`unfilteredResumeSortOrder` survive, and no filter row is
       carried across.

     Recorded earlier, and why 2b could not stand alone: a `SchemaV10` naming the unchanged live
     models is byte-identical to V9, and the plan rejects two versions sharing a checksum outright.
     Every migration test crashed on it — an uncaught ObjC exception, so the run hung rather than
     failing and the host had to be killed.
3. ✅ **Model layer.** `TagFilterField` + `TagFilter` (`ShuTaPla/Models/TagFilter.swift`) and
   `SavedSearch` as a `@Model`; `Playlist` carries `currentFilter`, the `savedSearches` relationship
   and `serviceFilterRaw` + computed `serviceFilter`. `FilterState`, `FilterMode` and `ResumeSlot`
   are gone (with the comment at `PlaybackCoordinator+Transport.swift`); `Playlist+Filtering` maps
   rewrite/drop over all four lists of every owned filter; `Playlist+ResumeSlot.swift` is now
   `Playlist+Resume.swift`, with `activeResumeSortOrder` a get/set pair that `captureResumePosition`
   writes through — one guard chain instead of two. `FilterStateTests`/`ResumeSlotTests` became
   `TagFilterTests`/`PlaylistResumeTests`, and the step-1 cascade probe is deleted now that the real
   pair carries the tests: `delete(filter)` reaps the search, `delete(search)` reaps the filter and
   leaves the playlist unfiltered, deleting the playlist converges both cascades without orphan or
   trap, and reassigning `currentFilter` fires no delete rule. Shim in place (`FilterBar` is a
   read-only summary with Clear; `PlaylistCenterView` reads `serviceFilter`).

   Two things the landing added beyond the written scope, each for a stated reason:
   - **Step 4's predicate port came along.** `sequencePredicate` had no meaning-preserving
     translation once the modes were gone, and an inert tag arm would have made `PlaylistTagsView`'s
     row tap silently do nothing — the "green build, silently unfiltered" state this plan rejects.
     So the proven builder is in `ModelContext+Sequence.swift` now (`fieldPredicate`,
     `countPredicate`, `andPredicate` as file-private free functions).
   - **One shared `appTestSchema`** (`ShuTaPlaTests/TestSchema.swift`, derived from `SchemaV10`)
     replaces ~27 hand-listed `Schema([...])` literals. The new entities made every subset an
     incomplete relationship graph, which fails the *container build* rather than an assertion — so
     the suites would have gone red for a reason unrelated to what they cover.

   `AppState+Filtering` is down to `toggleServiceFilter`, `setTagFilter(to:)`, `applySavedSearch`
   and `clearTagFilter`, all assigning through one private `apply(_:to:)` — the single place the
   outgoing row is disposed of (ad-hoc deleted, saved kept). The save/rename/delete/reorder API and
   the field-parameterized edits are still step 5's, and the `AppStateTests` cases that covered the
   old promote-to-top saving were dropped with it.
4. ✅ **Query layer.** The port itself came with step 3; what this step did was make the coverage
   guard it. `TagFilterPredicateTests` still held its own copies of `fieldPredicate` /
   `bothPredicate` / `tagFilterPredicate` from the step-1 probe, so every rule it pinned was pinned
   against a duplicate — the shipped builder could regress with the file green. It now drives the
   real path (attach a `TagFilter`, read `sequence(of:)`), the three copies are deleted, and the
   cost test's expected count comes from an independent pass in Swift rather than from evaluating
   the same predicate it measures, so the store and a plain reading of the four rules must agree.
   Production measures 1.68x the flat baseline and 1.00x for an all-empty filter row — the same
   order the probe saw, so the nested tree still translates.

   The rule coverage step 3 had put in `SequenceStoreTests` was the same coverage over a weaker
   fixture, so it is consolidated here, onto the a/b/c/ab/abc fixture built to discriminate the four
   rules; `SequenceStoreTests` keeps only `theServiceFilterWinsOverASetTagFilter`, which is about
   precedence between the two filter kinds and needs the triage rows. Added along the way: all four
   fields at once, and the contradictory tag (same name in a positive and a negative field) matching
   nothing — allowed rather than prevented, as the scope says.
5. ✅ **AppState API.** `toggleFilterTag(_:in:on:)` takes a `TagFilterField` (`setFilterMode` went
   with step 3) and is the single place a `TagFilter` row is created and destroyed, so the two
   directions cannot drift: inserted on the first token added to an unfiltered playlist, deleted when
   the last one leaves, taking any saved search with it through the cascade. `saveCurrentSearch`
   (returning `String?` naming the search that already covers the combination), `renameSavedSearch`,
   `deleteSavedSearch` and `moveSavedSearch(by:)` complete the surface. The asymmetry is pinned from
   both ends — and the pin ran green against the *unchanged* code first, so it holds `setTagFilter(to:)`
   still rather than only describing the new paths.

   Three things the step settled beyond the written scope:
   - **Deleting a search renumbers the survivors.** Not cosmetic: `saveCurrentSearch` appends at
     `savedSearches.count`, so a gap left by a delete makes the next save collide with a surviving
     row's `listOrder`. Proven by removing the renumber — the survivors sit at `[1, 2]` and the new
     search lands *between* them instead of last.
   - **`Playlist.sortedSavedSearches`** replaces the hand-rolled `sorted { $0.listOrder < … }` at
     every read site, and is what the reorder rewrites through.
   - **`SavedSearch.defaultName`** so the blank-name placeholder is one literal, shared by the model's
     init default and `AppState`'s trim.

   14 cases in `AppStateTests`, the row lifecycle swept over `TagFilterField.allCases`.
6. ✅ **Strip UI.** `FilterStrip` (`Views/FilterStrip/`) with `FilterFieldGrid` and
   `SavedSearchesDropdown` beside it, mounted in `PlaylistCenterView` and — as `showsTriage: false` —
   in `LibrarySurface`; `FilterBar` is deleted, `PlaylistCenterView` is down to the cache banner over
   the strip over the list, and `TagSidebar` is tag editing only.

   The precedence is the part that could rot silently, so it isn't in the view: `FilterStripMode`
   resolves it and `FilterStripLayout` packs the grid, both `nonisolated` and unit-tested the way
   `GalleryGrid` is (21 cases, swept over every combination the model can store). The pin ran red
   first — inverting it so a tag filter outranks a triage filter fails on the parked-filter case.

   Three things the step settled beyond the written scope:
   - **The delete confirmation is a `PendingConfirmation` case**, not a strip-local flag, so it joins
     `hasBlockingConfirmation` by construction rather than by a second registration. Its confirm arm
     is the only synchronous family (a store edit and its cascade, no file work to own), and the
     dropdown's trash goes through the same ask. The alert is hosted on the strip, as
     `PlaylistTagsView` hosts its own: only one strip is ever mounted, since the Manager carries no
     overlay (`RootView` mounts the audio layer in player mode only) and the two overlays that carry
     a `LibrarySurface` are mutually exclusive (`applyShow(.audioExtended)` drops `.visualOverlay`).
   - **The name field commits on two paths.** `[return]` and `Save` are the explicit ones; leaving
     the field or collapsing the strip commits a *rename* only. Creating a search stays `Save`'s
     alone, so a name typed over an ad-hoc filter and abandoned doesn't quietly become one.
     `onDisappear` carries the collapse case, since clicking `Filter` need not resign an AppKit
     field editor first.
   - **`Playlist.activeSavedSearch`** replaces `currentFilter?.savedSearch` at its three sites.

   One gap left here and closed after step 7 (see the head of this doc): the duplicate-save refusal
   was a strip-local `.alert`, as `PlaylistTagsView`'s and `TagEditorView`'s failures were, so it
   wasn't registered as blocking.

   A pass over the running strip closed its visual and interaction defects:
   - **The `Searches` panel closes on a click elsewhere**, via `ClickOutsideMonitor` — a local
     mouse-down monitor that reports without consuming, measuring in its own backing view's AppKit
     coordinates so no SwiftUI-global frames have to be kept in step. It is told the anchor row's
     height, since otherwise it closes the panel on the very mouse-down the `Searches` button then
     toggles back open. A `.popover` was tried and taken back out: it sizes to its content instead of
     the strip's width, and raising the delete confirmation dismisses it. The panel stays an overlay
     over the file list, now on an opaque `controlBackgroundColor` rather than a material — the
     thumbnails behind it read straight through anything translucent.
   - **A field's suggestion dropdown drew under the name row and under the cells around it.**
     `zIndex` only orders siblings, so `TagTokenField` reports open/closed (`onEditingChanged`) and
     `FilterFieldGrid` raises the open cell within its row, the row within the stack, and the grid
     as a whole over the name row. The stacks are plain: raising a cell inside the `LazyVGrid` the
     grid started as did not take, and laziness buys nothing over four fields.
   - **`Filter`, `Searches` and the field labels were `.secondary`** — greyed like disabled controls.
     They are primary now; the accent tint still marks which one carries the filter.
   - **The row's plain buttons hit-test their glyphs**, so the gap between a caret or glyph and its
     word fell through. Each label carries a `.contentShape(Rectangle())`.
   - **The panel is capped at ~six rows and scrolls past that.** Its content is measured rather than
     counted from a row height: an `.overlay` proposes the collapsed strip's height, which a
     `ScrollView` takes literally and shrinks to, while the two-line rows size themselves.
   - **A saved search's lists read as one pale run-on sentence**, labels and tag names alike. The
     row shows them as `FilterSummaryLine` instead: a short uppercase lead-in per filled field
     (`TagFilterField.shortLabel`) and the tags as the same chips the fields above use, tinted apart
     by `excludes` since two of the four lead-ins differ by a single word. It flows over as many
     lines as it needs, so no name is cut in half, and a field is one subview of the outer flow with
     an inner flow of its own — a wrap falls between blocks, never between a lead-in and its tags,
     unless the block alone is wider than a line. That last part needed `FlowLayout` to stop letting
     an oversized subview overflow and re-measure it against the line instead; its line breaking
     came out into `FlowLayoutPacking`, pure and now tested, which measuring and placing both call
     (they have to break lines identically). `TagFilter.summary` went with the old line — the only
     display site — and its test now covers `filledFields`, which the new one iterates.
   - **The applied search's row smeared a shadow of its own** and washed its chips out in blue. Its
     highlight is the system's unfocused-list gray now, since the row is mostly accent pills; the
     smear was `.shadow` reaching every shape drawn inside the panel, so the panel's chrome —
     rounded, bordered, clipped, composited, shadowed — is one `floatingPanel` modifier that the
     suggestion dropdown shares, and the compositing is stated once instead of remembered at each
     call. The clip then carved the corner radius out of the edge rows' full-bleed highlight, which
     a rounded panel and edge-to-edge rows can't both avoid: the searches panel takes a radius of
     zero, which suits a panel as wide as the strip it hangs from, and the narrow suggestion
     dropdown keeps the default.
   - **A token field's height followed what it held** — a chip row, a lone placeholder, and the
     AppKit input are three different heights — so fields standing side by side in the grid didn't
     line up and one grew as it was filled. One figure covers all three now, and it is the chip that
     came down to the other two rather than the reverse: the chip was as tall as the ✕'s hit box,
     which is generous beside caption-scale text, and it was pulling the whole strip open.
   - **`Delete saved search` didn't read as destructive.** The `role` was already on it — macOS
     renders a role only in menus and alerts, so a button standing in a row states it itself, and
     the role stays for the alert and for accessibility. The dropdown's per-row trash is left
     untinted: the glyph already says it, and one in every row would read as a wall of warnings.
   - **The name field could only be left by focusing another field**, so a click on the file list
     left the caret in it and the rename that fires on losing focus never did. The same
     `ClickOutsideMonitor` resigns it — mounted only while focused, so the click that focuses the
     field is never the one that resigns it. That is why the monitor is in `Views/Shared/`.
7. ✅ **Docs.** The control is the **Filter Strip** throughout now, matching the code and the surface
   it became — a strip over the file list, not a bar in the inspector.

   `doc/features/filtering.md` is rewritten around the four fields as a table, with the strip's own
   collapsed/expanded shape, the four-case precedence between a review mode, a Service Filter and a
   tag filter (previously stated only as "the tag filter is temporarily inactive"), and persistence
   bullets that carry the new rules: naming rather than uniqueness, editing a search by editing the
   filter, insertion order rewritten only by the row buttons, and a removal discarding a search only
   when all four of its lists empty. The grouped-expressions "Future direction" line is gone — the
   four fields *are* it, bar a top-level OR, which the scope paragraph now states in place.

   `doc/features.md` carries the glossary entry and the chapter-map row; `manager-mode.md`,
   `players.md` and `tags.md` take the sidebar → center-strip move, which also empties the right
   panel's description of its filtering half.

   `doc/architecture.md` needed more than the three known lines. §3 counts seven entities and sketches
   `TagFilter`/`SavedSearch`, with two new decision bullets — why filters are rows (the per-file-switch
   write, the mutual cascade, the write-through, the unreachable-row invariant) and how the four fields
   compose at runtime, pointing at the ceiling written up in the code rather than restating it. Beyond
   those: the `Playlist` sketch, the data-flow bullet, the `TagTokenField` call site, §6's new **Filter
   strip** subsection (the two tested pure decisions, the overlay-over-popover choice and the
   per-level `zIndex`), §14's `Views/` tree, §15's embedded-value-types rationale, §17's future
   direction (now top-level OR alone), and the cache banner's "notice strip", a surface that no longer
   exists. `doc/versioning.md` needed nothing — it is written against `SchemaVN` placeholders and step
   2b already put its lessons there.
