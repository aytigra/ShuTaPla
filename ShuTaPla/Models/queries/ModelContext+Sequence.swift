//
//  ModelContext+Sequence.swift
//  ShuTaPla
//
//  The order a playlist's file list shows and playback walks, derived store-side. One rule —
//  the playlist's *effective filter*: the triage filter when one is set, otherwise the
//  persisted tag filter — expressed as a predicate so the store does the filtering, sorts
//  by `sortOrder`, and returns just the ordered `PersistentIdentifier`s. Skipped (wrong-type)
//  files are excluded from every filter, so one sequence serves both the file list and playback;
//  the skipped files themselves are reached only through `skippedSequence`, the review tool's list.
//  No whole-set materialization: a caller resolves only the rows it actually shows via `model(for:)`.
//
//  The triage filter and `taggingStatus` ride scalar columns (`isSkipped`,
//  `taggingStatusCode`) and the tag filter rides the `Tag` relationship, all of which a
//  `#Predicate` can compare — the enum itself cannot be captured.
//
//  `includePendingChanges` is `false` on every fetch, so a mutation must be saved before its
//  sequence is re-derived. That keeps an unsaved edit from leaking a stale or pending row into
//  the result.
//

import Foundation
import SwiftData

extension ModelContext {
    /// Ordered identifiers a file list shows and playback walks under the playlist's effective
    /// filter: the triage filter's set when one is set (untagged / invalid-tagging), otherwise the
    /// tag-filtered files. Skipped files are excluded throughout.
    func sequence(of playlist: Playlist) -> [PersistentIdentifier] {
        identifiers(matching: sequencePredicate(for: playlist))
    }

    /// The playlist's *skipped* files — wrong-type/unplayable rows a scan flagged — in `sortOrder`.
    /// The skipped-review tool's list, swapped in for `sequence` while its mode is active. Skipped
    /// files never appear in `sequence`, so this is the only surface that lists them (for delete /
    /// show-in-folder / rename); they are unplayable, so there is no playback counterpart.
    func skippedSequence(of playlist: Playlist) -> [PersistentIdentifier] {
        let pid = playlist.persistentModelID
        return identifiers(matching: #Predicate { $0.playlist?.persistentModelID == pid && $0.isSkipped })
    }

    /// The playlist's *duplicate* files — those whose content fingerprint recurs (count ≥ 2) —
    /// grouped by fingerprint so each duplicate set is adjacent, ordered by fingerprint. The
    /// find-duplicates tool's sequence, swapped in for `sequence` while its mode is active.
    /// The grouping is a pass in Swift, not a `#Predicate` sorted by `sortOrder`, so it sits here
    /// rather than in the effective-filter machinery. Only the thumbnail producer fills a
    /// fingerprint, so a file never shown in the gallery (and every file of a list-only audio
    /// playlist) carries none and is absent by construction — the tool's documented coverage limit.
    func duplicateSequence(of playlist: Playlist) -> [PersistentIdentifier] {
        let pid = playlist.persistentModelID
        var descriptor = FetchDescriptor<PlaylistFile>(
            predicate: #Predicate { $0.playlist?.persistentModelID == pid && $0.fingerprint != nil },
            sortBy: [SortDescriptor(\.fingerprint), SortDescriptor(\.sortOrder)]
        )
        descriptor.includePendingChanges = false
        descriptor.propertiesToFetch = [\.fingerprint]
        let files = (try? fetch(descriptor)) ?? []

        var counts: [String: Int] = [:]
        for file in files { counts[file.fingerprint ?? "", default: 0] += 1 }
        return files.compactMap { file in
            guard let fingerprint = file.fingerprint, counts[fingerprint, default: 0] >= 2 else { return nil }
            return file.persistentModelID
        }
    }

    /// `sequence` resolved to models, in order.
    ///
    /// Test-only helper — must never be used in the app: it faults **every** row of the sequence
    /// into the context on the main actor, exactly the O(folder) materialization the identifier
    /// sequences exist to avoid. Production holds `sequence` and resolves only the rows a surface
    /// shows via `model(for:)`, or resolves a single remembered file through `PlaybackSequences.member`.
    func sequenceFiles(of playlist: Playlist) -> [PlaylistFile] {
        sequence(of: playlist).compactMap { model(for: $0) as? PlaylistFile }
    }

    /// The file a filter change resumes to, resolved store-side: the first sequence file whose
    /// `sortOrder` is at or after `minSortOrder`, wrapping to the first sequence file when none
    /// qualify, `nil` when the sequence is empty. At most two one-row fetches — the bounded
    /// `fetchLimit: 1`, and (only on wrap) the sequence's first identifier — never the whole
    /// sequence materialized.
    func resumeTarget(of playlist: Playlist, atOrAfter minSortOrder: Int) -> PlaylistFile? {
        var descriptor = FetchDescriptor<PlaylistFile>(
            predicate: sequencePredicate(for: playlist, atOrAfter: minSortOrder),
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = false
        if let bounded = (try? fetch(descriptor))?.first { return bounded }
        // Nothing at or after the bound — wrap to the sequence's first file, already an ordered id.
        return sequence(of: playlist).first.flatMap { model(for: $0) as? PlaylistFile }
    }

    /// Whether `sequence` would contain any file, answered with a `fetchCount` rather than
    /// building the sequence.
    func sequenceNotEmpty(in playlist: Playlist) -> Bool {
        count(sequencePredicate(for: playlist)) > 0
    }

    /// The playlist's total file count, answered with a `fetchCount` — the sidebar row badge, so
    /// the whole `files` relationship is never faulted just to read its length.
    func fileCount(in playlist: Playlist) -> Int {
        let pid = playlist.persistentModelID
        return count(#Predicate { $0.playlist?.persistentModelID == pid })
    }

    /// The playlist's files whose relative path is one of `paths`, resolved without faulting the
    /// whole `files` relationship — the live cloud feed folds only the handful of paths a metadata
    /// update reports, so a frequent progress tick never materializes the folder on the main actor.
    /// Scoped by the `(playlist, …)` index; the returned models are the context's live instances, so
    /// writing `cloudStatus` on them reaches every observer.
    func files(in playlist: Playlist, atRelativePaths paths: Set<String>) -> [PlaylistFile] {
        guard paths.isNotEmpty else { return [] }
        let pid = playlist.persistentModelID
        let pathList = Array(paths)
        var descriptor = FetchDescriptor<PlaylistFile>(
            predicate: #Predicate { $0.playlist?.persistentModelID == pid && pathList.contains($0.relativePath) }
        )
        descriptor.includePendingChanges = false
        return (try? fetch(descriptor)) ?? []
    }

    /// The three triage counts — untagged / invalid-tagging / skipped — for the center's notice
    /// bar, each a `fetchCount` over the scalar columns.
    func serviceFilterCounts(for playlist: Playlist) -> (untagged: Int, invalidTagging: Int, skipped: Int) {
        let pid = playlist.persistentModelID
        let untagged = count(triagePredicate(pid: pid, code: TaggingStatus.untagged.code))
        let invalidTagging = count(triagePredicate(pid: pid, code: TaggingStatus.invalid.code))
        let skipped = count(#Predicate { $0.playlist?.persistentModelID == pid && $0.isSkipped })
        return (untagged, invalidTagging, skipped)
    }

    /// The file with row identity `id` if its row still exists, else nil — a bounded one-row fetch on
    /// the entity's own identity, the seam both the Manager row render (`AppState.file(for:)`) and the
    /// coordinator's sequence walk (`resolveFile`) resolve one id at a time through, never the whole
    /// sequence. Not `model(for:)`: that hands back a **non-nil invalidated instance** for a
    /// deleted-and-saved row — its context, `isDeleted`, and registration all still read as live — whose
    /// first persisted-property read traps; a fetch drops the deleted row and returns nil. The default
    /// `includePendingChanges` keeps it equivalent to `model(for:)` for live rows: a pending insert
    /// still resolves (its temporary id matches) and a dirty registered row is returned unchanged
    /// (no refault). The `persistentModelID` comparison resolves on the entity's primary-key index,
    /// so the per-call cost is constant in the row count — measured flat (0.86x) across a 10x growth
    /// in `FileResolutionScalingTests` — which keeps a full Manager render O(visible rows), not O(N²),
    /// even though this runs once per visible row per `body`.
    func file(for id: PersistentIdentifier) -> PlaylistFile? {
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    /// The persistent identifier of the file with app id `fileID`, or nil if none exists — a
    /// one-row fetch used to resolve a single file (and back the `PlaybackSequences.member`
    /// membership test) without resolving the whole set.
    func identifier(of fileID: UUID) -> PersistentIdentifier? {
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: #Predicate { $0.id == fileID })
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = false
        return (try? fetchIdentifiers(descriptor))?.first
    }

    // MARK: - Fetch primitives

    private func identifiers(matching predicate: Predicate<PlaylistFile>) -> [PersistentIdentifier] {
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: predicate, sortBy: [SortDescriptor(\.sortOrder)])
        descriptor.includePendingChanges = false
        return (try? fetchIdentifiers(descriptor)) ?? []
    }

    private func count(_ predicate: Predicate<PlaylistFile>) -> Int {
        var descriptor = FetchDescriptor<PlaylistFile>(predicate: predicate)
        descriptor.includePendingChanges = false
        return (try? fetchCount(descriptor)) ?? 0
    }

    // MARK: - Effective-filter predicate

    /// The effective-filter predicate the file list and playback share: triage filter when set,
    /// otherwise the tag filter (or all non-skipped files when no filter is active). Skipped files
    /// are excluded throughout — they are never listed or played, only reached via `skippedSequence`.
    /// `atOrAfter` adds a lower `sortOrder` bound — `.min` (the default) means no bound, so every
    /// list/sequence caller keeps its behavior; `resumeTarget` passes a real bound to fetch the
    /// first file from a point.
    ///
    /// Only the *filled* fields are built, so an empty field contributes no subquery and an
    /// all-empty filter composes down to the scalar scope itself — which is why there is no
    /// separate unfiltered fast path.
    private func sequencePredicate(for playlist: Playlist, atOrAfter minSortOrder: Int = .min) -> Predicate<PlaylistFile> {
        let pid = playlist.persistentModelID

        if let service = playlist.serviceFilter {
            switch service {
            case .untagged:
                return triagePredicate(pid: pid, code: TaggingStatus.untagged.code, atOrAfter: minSortOrder)
            case .invalidTagging:
                return triagePredicate(pid: pid, code: TaggingStatus.invalid.code, atOrAfter: minSortOrder)
            }
        }

        let scope = #Predicate<PlaylistFile> { file in
            file.playlist?.persistentModelID == pid && !file.isSkipped && file.sortOrder >= minSortOrder
        }
        guard let filter = playlist.currentFilter else { return scope }
        return filter.filledFields.reduce(scope) { combined, filled in
            // Deduped and lowercased per field, so a tag typed twice (or in two casings) can never
            // raise must-have-all's threshold past what any file can reach.
            let names = Array(Set(filled.tags.map { $0.lowercased() }))
            return andPredicate(combined, fieldPredicate(filled.field, names: names))
        }
    }

    /// A triage-filter predicate: the playlist's non-skipped files with a given tagging-status
    /// code. Shared by the untagged / invalid-tagging filter arms and their notice-bar counts.
    /// `atOrAfter` threads the same optional `sortOrder` bound as `sequencePredicate`.
    private func triagePredicate(pid: PersistentIdentifier, code: Int, atOrAfter minSortOrder: Int = .min) -> Predicate<PlaylistFile> {
        #Predicate {
            $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.taggingStatusCode == code
                && $0.sortOrder >= minSortOrder
        }
    }
}

// MARK: - Tag-filter clauses

/// One field's rule, as a threshold against the count of the file's tags that appear in `names`:
/// must-have-all ≥ n, must-have-any ≥ 1, must-not-have-all < n, must-not-have-any < 1. Every field
/// collapses to that one comparison, so the four differ only in two numbers.
private func fieldPredicate(_ field: TagFilterField, names: [String]) -> Predicate<PlaylistFile> {
    switch field {
    case .mustHaveAll: return countPredicate(names: names, threshold: names.count, atLeast: true)
    case .mustHaveAny: return countPredicate(names: names, threshold: 1, atLeast: true)
    case .mustNotHaveAll: return countPredicate(names: names, threshold: names.count, atLeast: false)
    case .mustNotHaveAny: return countPredicate(names: names, threshold: 1, atLeast: false)
    }
}

/// A single flat subquery over `file.tags` compared against `threshold` — the shape a `#Predicate`
/// translates to SQL. A nested `allSatisfy { tags.contains { … } }` over a captured array is an
/// unsupported subquery that traps at fetch, so the count stands in for it and the negatives negate
/// the same flat shape rather than reintroducing one.
private func countPredicate(names: [String], threshold: Int, atLeast: Bool) -> Predicate<PlaylistFile> {
    atLeast
        ? #Predicate<PlaylistFile> { file in
            file.tags.filter { names.contains($0.normalizedName) }.count >= threshold
        }
        : #Predicate<PlaylistFile> { file in
            file.tags.filter { names.contains($0.normalizedName) }.count < threshold
        }
}

/// Two predicates AND-joined by nesting them with `.evaluate(_:)`.
///
/// The four fields cannot live in one `#Predicate`: the macro expands to a single deeply nested
/// generic expression and the type-checker gives up ("unable to type-check this expression in
/// reasonable time") at roughly three `file.tags` subqueries or four conjuncts — it is the whole
/// expression's complexity, not the subqueries as such. Folding small predicates pairwise keeps
/// every expansion far under that ceiling; runtime nesting depth is unconstrained, and SwiftData
/// still translates the nested node to SQL, so the fetch stays one store-side query.
private func andPredicate(
    _ lhs: Predicate<PlaylistFile>, _ rhs: Predicate<PlaylistFile>
) -> Predicate<PlaylistFile> {
    #Predicate<PlaylistFile> { file in lhs.evaluate(file) && rhs.evaluate(file) }
}
