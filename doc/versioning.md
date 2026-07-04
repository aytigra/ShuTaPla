# SwiftData schema versioning

**Read this before changing any `@Model`.** A schema change compiles fine and then **crashes the
app at launch** if you forget the migration — it is never a build error, so the compiler won't warn
you.

## The setup

`ShuTaPlaApp` builds the container from the current versioned schema plus a migration plan:

```swift
let schema = Schema(versionedSchema: <current SchemaVN>.self)
ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: […])
```

- The **current `SchemaVN`** (`Models/Migrations/`) lists the live top-level model types, so it
  always tracks whatever they declare.
- **`AppMigrationPlan`** registers the schema versions and the stages between them. It is the one
  place a new version is registered.

## The failure mode

Any change to a model's **stored shape** changes the store's schema hash. When the app opens an
existing store whose hash no longer matches the current schema, and no migration stage bridges the
two, `ModelContainer(for:…)` throws a `loadIssue` and `ShuTaPlaApp`'s `fatalError` fires — **crash
on launch, not a build failure.**

## What is a stored-shape change (needs a new version + stage)

- Add, remove, or rename a **stored** property.
- Add or remove `#Unique` or `@Attribute(.unique)` — a uniqueness *constraint* is part of the hash.
- Add or remove a **member of a Codable struct stored as a composite attribute** — a single Codable
  struct property (no `@Attribute`) is persisted as a *structured composite*, so its members are
  part of the entity hash.
- Change a stored property's type.

## What is NOT (no version needed)

- Computed properties, methods, static members.
- Changing the contents/coding of a value that rides a **JSON blob** — e.g. a `[Codable]` array is
  stored as one opaque blob, so adding a field to its element shape isn't a schema column. Contrast
  with the composite-attribute case above: that distinction is the subtle one.
- Adding or removing a fetch index (`#Index`) — but this one is a trap; see below.

## The fetch-index trap: `#Index` never reaches an existing store on its own

Fetch indexes (`#Index`) are **excluded from CoreData's entity version hash**. So adding one is a
double-edged non-event:

- It does **not** need a stage to *open* an existing store — the hash is unchanged, so the store
  stays compatible and the app launches fine (no `loadIssue`, unlike a real stored-shape change).
- But for the same reason CoreData sees the store as already matching the current model, so **no
  migration runs and the index is never created**. A store built fresh (a new install) gets the
  index; every store that already exists stays unindexed forever. A version bump with a lightweight
  stage does *not* fix this — the hash still matches, so the stage is skipped (Apple WWDC 2017
  Session 210). CoreData's own remedy, `versionHashModifier`, is not surfaced by SwiftData.

**The fix: perturb the hash so a migration runs, and it reconciles every entity's indexes.** A
running migration — triggered by *any* hash change, on *any* entity — rebuilds the destination
schema and reconciles all declared indexes, not just the changed entity's. So the trigger can live
on a **separate table**. `SchemaMarker` is exactly that: a permanent, empty `@Model` added in the
same release as the index. Every pre-existing store lacks it, so the hash always mismatches → the
lightweight stage always runs → the index is applied, regardless of which prior version the user
came from (a direct old→new jump would otherwise short-circuit on the matching hash). Keep the
marker forever — removing it re-opens the skip. It is the reusable lever for the next forgotten
index: perturb it (add or rename a property) in that release. Column deletion, by contrast, *is* a
supported lightweight change, so a throwaway column is never needed.

## Recipe: add the next version

1. **Freeze the current shape.** The current `SchemaVN` references live types; before you change
   the models, give it explicit pinned `@Model` copies of the models *as they are now* (the
   pre-change shape). Pin the **whole relationship component together** — copying one model drags
   the models it relates to, because their relationships must resolve to same-version types. Models
   with no relationship into the changed component can keep referencing the live types.
2. **Create the new `SchemaV(N+1)`**: a fresh `versionIdentifier`, with `models` referencing the
   **live** types.
3. **Make the live model change.**
4. **Register it in `AppMigrationPlan`:** add the new version to `schemas`, and append a stage from
   the old version to the new one.
5. **Point `ShuTaPlaApp` at the new version.**
6. **Add a migration test** (below).

### Lightweight vs custom stage

- **`.lightweight`** — SwiftData maps old → new automatically. Use for additive optional columns,
  index/unique changes, dropped columns, and an added composite member with a default. No code.
- **Custom `MigrationStage`** — only when you must *derive or transform* data: a new non-optional
  property with no default, a type change, splitting/merging fields. Write `willMigrate`/
  `didMigrate` to compute the values.

Values that are recomputed from another source of truth (e.g. anything rebuilt on the next folder
scan) never need migrating as data, which keeps most additive changes lightweight.

## Testing a migration

Prove the stage preserves the non-derivable rows:

1. Create a store at the **old** pinned schema on disk and save rows through it, then release that
   container so it flushes.
2. Reopen the same store URL through `AppMigrationPlan` into the **new** current schema.
3. Assert the non-derivable rows survived, and any new columns start empty (a rebuild repopulates
   the derived ones).

Hold the `ModelContainer` for the whole test body and use a temp store URL you delete in a `defer`
(see the SwiftData test-trap notes in CLAUDE.md).
