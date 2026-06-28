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
        let untagged = count(triagePredicate(pid: pid, code: TaggingStatus.untagged.code))
        let invalidTagging = count(triagePredicate(pid: pid, code: TaggingStatus.invalid.code))
        let skipped = count(#Predicate { $0.playlist?.persistentModelID == pid && $0.isSkipped })
        return (untagged, invalidTagging, skipped)
    }

    /// The file with app id `fileID` if it survives `playlist`'s effective *display* filter,
    /// else nil — the display-view membership test for one file (the Files & Tags overlay's
    /// current file, a scope/selection re-seed). Resolves just that one file and evaluates the
    /// effective filter on it, rather than building the whole sequence to scan for it.
    func displayMember(_ fileID: UUID, of playlist: Playlist) -> PlaylistFile? {
        member(fileID, matching: displayPredicate(for: playlist))
    }

    /// The file with app id `fileID` if it survives `playlist`'s effective *playback* filter,
    /// else nil — the playback-view counterpart of `displayMember` (the audio overlay's current
    /// track), so a skipped track is never current.
    func playbackMember(_ fileID: UUID, of playlist: Playlist) -> PlaylistFile? {
        member(fileID, matching: playbackPredicate(for: playlist))
    }

    /// Resolves the one file with app id `fileID` and returns it only if it satisfies
    /// `predicate`. The predicate is evaluated in memory on the single resolved model — callers
    /// read this right after a `persistAndRefresh`, so the live model equals the saved row the
    /// sequence accessors (`includePendingChanges: false`) would return.
    private func member(_ fileID: UUID, matching predicate: Predicate<PlaylistFile>) -> PlaylistFile? {
        guard let pid = identifier(of: fileID), let file = model(for: pid) as? PlaylistFile,
              (try? predicate.evaluate(file)) == true else { return nil }
        return file
    }

    /// The persistent identifier of the file with app id `fileID`, or nil if none exists — a
    /// one-row fetch used to resolve a single file (and back the `displayMember`/`playbackMember`
    /// membership tests) without resolving the whole set.
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

    // MARK: - Effective-filter predicates

    /// The effective-filter predicate for the file list: triage filter when set, otherwise the
    /// tag filter (or all non-skipped files when no filter is active).
    private func displayPredicate(for playlist: Playlist) -> Predicate<PlaylistFile> {
        let pid = playlist.persistentModelID
        let filter = playlist.filterState

        if let service = filter.serviceFilter {
            switch service {
            case .untagged:
                return triagePredicate(pid: pid, code: TaggingStatus.untagged.code)
            case .invalidTagging:
                return triagePredicate(pid: pid, code: TaggingStatus.invalid.code)
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

    /// A triage-filter predicate: the playlist's non-skipped files with a given tagging-status
    /// code. Shared by the untagged / invalid-tagging display arms and their notice-bar counts.
    private func triagePredicate(pid: PersistentIdentifier, code: Int) -> Predicate<PlaylistFile> {
        #Predicate { $0.playlist?.persistentModelID == pid && !$0.isSkipped && $0.taggingStatusCode == code }
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
