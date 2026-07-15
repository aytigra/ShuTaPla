//
//  ModelContext+Sequence.swift
//  ShuTaPla
//
//  The order a playlist's file list shows and playback walks, derived store-side. One rule —
//  the playlist's *effective filter*: the triage filter when one is set, otherwise the
//  persisted tag filter — expressed as a `#Predicate` so the store does the filtering, sorts
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
    /// shows via `model(for:)`, or fetches the one row it needs (`sequenceMember`).
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

    /// The file with app id `fileID` if it survives `playlist`'s effective filter, else nil — the
    /// membership test for one file (a channel's current file, a scope/selection re-seed). Resolves
    /// just that one file and evaluates the effective filter on it, rather than building the whole
    /// sequence to scan for it. A skipped file never survives, so it is never a channel's current file.
    func sequenceMember(_ fileID: UUID, of playlist: Playlist) -> PlaylistFile? {
        guard let pid = identifier(of: fileID), let file = model(for: pid) as? PlaylistFile,
              (try? sequencePredicate(for: playlist).evaluate(file)) == true else { return nil }
        return file
    }

    /// The persistent identifier of the file with app id `fileID`, or nil if none exists — a
    /// one-row fetch used to resolve a single file (and back the `sequenceMember` membership test)
    /// without resolving the whole set.
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
    private func sequencePredicate(for playlist: Playlist, atOrAfter minSortOrder: Int = .min) -> Predicate<PlaylistFile> {
        let pid = playlist.persistentModelID
        let filter = playlist.filterState

        if let service = filter.serviceFilter {
            switch service {
            case .untagged:
                return triagePredicate(pid: pid, code: TaggingStatus.untagged.code, atOrAfter: minSortOrder)
            case .invalidTagging:
                return triagePredicate(pid: pid, code: TaggingStatus.invalid.code, atOrAfter: minSortOrder)
            }
        }

        guard filter.isNotEmpty else {
            return #Predicate { $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.sortOrder >= minSortOrder }
        }

        let names = Array(Set(filter.selectedTags.map { $0.lowercased() }))
        // The `.and`/`.notAll` pair counts the file's selected tags: `names` is deduped, so a file
        // carries all of them iff that count equals `required`. A nested
        // `allSatisfy { tags.contains { … } }` is an unsupported subquery, so this flat count stands
        // in for it — and the negatives negate the same flat shapes (no subquery reintroduced).
        let required = names.count
        switch filter.filterMode {
        case .or:
            return #Predicate { file in
                file.playlist?.persistentModelID == pid && !file.isSkipped && file.sortOrder >= minSortOrder
                    && file.tags.contains { names.contains($0.normalizedName) }
            }
        case .notAny:
            return #Predicate { file in
                file.playlist?.persistentModelID == pid && !file.isSkipped && file.sortOrder >= minSortOrder
                    && !file.tags.contains { names.contains($0.normalizedName) }
            }
        case .and:
            return #Predicate { file in
                file.playlist?.persistentModelID == pid && !file.isSkipped && file.sortOrder >= minSortOrder
                    && file.tags.filter { names.contains($0.normalizedName) }.count == required
            }
        case .notAll:
            return #Predicate { file in
                file.playlist?.persistentModelID == pid && !file.isSkipped && file.sortOrder >= minSortOrder
                    && file.tags.filter { names.contains($0.normalizedName) }.count != required
            }
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
