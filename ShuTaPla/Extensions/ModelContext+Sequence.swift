//
//  ModelContext+Sequence.swift
//  ShuTaPla
//
//  The order a playlist's file lists show and playback walks, derived store-side. One rule —
//  the playlist's *effective filter*: the triage filter when one is set, otherwise the
//  persisted tag filter — expressed as a `#Predicate` so the store does the filtering, sorts
//  by `sortOrder`, and returns just the ordered `PersistentIdentifier`s. No whole-set
//  materialization: a caller resolves only the rows it actually shows via `model(for:)`.
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
    /// Ordered identifiers a file list shows under the playlist's effective filter: the triage
    /// filter's set when one is set (untagged / invalid-tagging / skipped), otherwise the
    /// tag-filtered playable files. Can include skipped files (under the skipped filter).
    func displaySequence(of playlist: Playlist) -> [PersistentIdentifier] {
        identifiers(matching: displayPredicate(for: playlist))
    }

    /// Ordered identifiers playback walks: `displaySequence` with skipped files removed, so
    /// advancing wraps the playable set. Empty under the skipped filter.
    func playbackSequence(of playlist: Playlist) -> [PersistentIdentifier] {
        identifiers(matching: playbackPredicate(for: playlist))
    }

    /// `displaySequence` resolved to models, in order — for callers that need the files
    /// themselves (the Manager and overlay lists, a reconcile that inspects the current file).
    /// This resolves every row, so a surface that shows only part of a large sequence should
    /// hold the identifiers and resolve the visible rows lazily instead.
    func displayFiles(of playlist: Playlist) -> [PlaylistFile] {
        displaySequence(of: playlist).compactMap { model(for: $0) as? PlaylistFile }
    }

    /// `playbackSequence` resolved to models, in order — what the coordinator walks to find the
    /// next/previous file and what playback starts from.
    func playbackFiles(of playlist: Playlist) -> [PlaylistFile] {
        playbackSequence(of: playlist).compactMap { model(for: $0) as? PlaylistFile }
    }

    /// Whether `playbackSequence` would contain any file, answered with a `fetchCount` rather
    /// than building the sequence.
    func hasPlaybackFiles(in playlist: Playlist) -> Bool {
        count(playbackPredicate(for: playlist)) > 0
    }

    /// The three triage counts — untagged / invalid-tagging / skipped — for the center's notice
    /// bar, each a `fetchCount` over the scalar columns.
    func serviceFilterCounts(for playlist: Playlist) -> (untagged: Int, invalidTagging: Int, skipped: Int) {
        let pid = playlist.persistentModelID
        let untaggedCode = TaggingStatus.untagged.code
        let invalidCode = TaggingStatus.invalid.code
        let untagged = count(#Predicate {
            $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.taggingStatusCode == untaggedCode
        })
        let invalidTagging = count(#Predicate {
            $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.taggingStatusCode == invalidCode
        })
        let skipped = count(#Predicate {
            $0.playlist?.persistentModelID == pid && $0.isSkipped
        })
        return (untagged, invalidTagging, skipped)
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

    // MARK: - Effective-filter predicates

    /// The effective-filter predicate for the file list: triage filter when set, otherwise the
    /// tag filter (or all non-skipped files when no filter is active).
    private func displayPredicate(for playlist: Playlist) -> Predicate<PlaylistFile> {
        let pid = playlist.persistentModelID
        let filter = playlist.filterState

        if let service = filter.serviceFilter {
            switch service {
            case .untagged:
                let code = TaggingStatus.untagged.code
                return #Predicate {
                    $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.taggingStatusCode == code
                }
            case .invalidTagging:
                let code = TaggingStatus.invalid.code
                return #Predicate {
                    $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.taggingStatusCode == code
                }
            case .skipped:
                return #Predicate { $0.playlist?.persistentModelID == pid && $0.isSkipped }
            }
        }

        guard !filter.isEmpty else {
            return #Predicate { $0.playlist?.persistentModelID == pid && !$0.isSkipped }
        }

        let names = Array(Set(filter.selectedTags.map { $0.lowercased() }))
        switch filter.filterMode {
        case .or:
            return #Predicate { file in
                file.playlist?.persistentModelID == pid && !file.isSkipped
                    && file.tags.contains { names.contains($0.normalizedName) }
            }
        case .and:
            // A nested `allSatisfy { tags.contains { … } }` is an unsupported subquery; instead
            // count the file's tags that are in the selected set and require all of them present.
            // `names` is deduped, so a match needs exactly `required` of its (distinct) tags.
            let required = names.count
            return #Predicate { file in
                file.playlist?.persistentModelID == pid && !file.isSkipped
                    && file.tags.filter { names.contains($0.normalizedName) }.count == required
            }
        }
    }

    /// Playback drops skipped files. The skipped triage filter therefore plays nothing; every
    /// other effective filter already excludes skipped files, so its display predicate is its
    /// playback predicate.
    private func playbackPredicate(for playlist: Playlist) -> Predicate<PlaylistFile> {
        if playlist.filterState.serviceFilter == .skipped {
            return #Predicate { _ in false }
        }
        return displayPredicate(for: playlist)
    }
}
