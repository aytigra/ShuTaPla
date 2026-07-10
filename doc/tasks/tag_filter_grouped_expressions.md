# Task — Grouped tag filter expressions

Let a playlist's tag filter be a nested boolean expression over tags — e.g.
`A AND B AND (C OR D)`, with negation — rather than the flat single-list AND/OR/Not-all/Not-any
of the [negation task](tag_filter_negation.md). This is the `doc/features/filtering.md` "Future
direction" grouped-expressions goal.

Not started. Depends on the negation task landing first (it settles the flat model this generalizes).

## Path forward

### Model — an expression tree, still an embedded Codable blob

Replace `FilterState`'s flat `selectedTags` + `filterMode` with a recursive expression:

```swift
indirect enum FilterExpr: Codable, Sendable, Equatable {
    case tag(String)
    case not(FilterExpr)
    case and([FilterExpr])
    case or([FilterExpr])
}
```

Still a JSON blob on `Playlist` — **no SwiftData migration**, only a new blob shape, with
back-compat decoding from the flat `{selectedTags, filterMode}` form (map it to the equivalent
`and`/`or`/`not` tree on read). `SavedSearch` stores a `FilterExpr` instead of `tags + mode`; its
`matches()` becomes tree-equality. The tag rewrite/drop machinery in `Playlist+Filtering` walks the
tree instead of a flat `[String]`.

### Evaluation — set algebra over per-leaf ID fetches, not one predicate

The store-side `#Predicate` cannot express a nested boolean tree over the to-many `tags`
relationship (nested subquery — the wall the flat `.and` arm already works around), and the only
route that could (a private Core Data `NSPredicate` `SUBQUERY` bridge) is unstable and rejected.

Evaluate the tree as **set algebra over identifier sets**, all public API, in `ModelContext+Sequence`:

1. Per distinct leaf `tag`, one flat `fetchIdentifiers` (the existing single-tag membership
   predicate, `(playlist, isSkipped)`-narrowed) → a `Set<PersistentIdentifier>`. Dedup so each tag
   is fetched once and reused across groups.
2. Fold the tree in Swift: `and` = intersection, `or` = union, `not` = playlist-set minus.
3. Final ordered fetch: `#Predicate { finalIDs.contains($0.id) }` sorted by `sortOrder` — the store
   still sorts and returns only identifiers, preserving the no-materialization invariant.

Cost is linear in the number of *distinct tags in the expression*, not in files, and runs only on a
user-driven filter change. Optional refinement if an expression can match most of a large playlist:
carry `sortOrder` alongside `id` in step 1 and sort surviving pairs in memory, skipping the final
`IN`-list fetch. `displayPredicate`/`playbackPredicate` become "resolve the tree to an ID set" — the
service filters and `!isSkipped` handling stay as they are; only the tag arm changes.

### UI — the expression builder is the bulk of the work

The flat chip control gives way to a builder: add a group, choose its operator, negate a
leaf/group, nest. This is the hardest and least-defined part — design it before implementation, and
settle how deep nesting the UI exposes (the model is unbounded; the UI need not be).

## Open questions to settle before coding

- Builder UX and nesting depth exposed.
- Whether saved searches and per-filter resume positions extend to arbitrary trees unchanged
  (identity = tree-equality) or need constraining.
- Interaction with the flat negation modes once both exist (the flat modes are a strict subset —
  keep the simple bar as the default surface and the builder as an opt-in?).
