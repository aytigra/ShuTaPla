//
//  Playlist+Playback.swift
//  ShuTaPla
//
//  The order playback walks through a playlist and the order its file lists show. Both
//  derive from one rule — the playlist's *effective filter*: the triage filter when one is
//  set, otherwise the persisted tag filter. It lives on the model so the Manager, the
//  overlays, and the coordinator all reach the same sequence without duplicating the rule.
//

import Foundation

extension Playlist {
    /// Files in display order under the effective filter: the triage filter's set when one is
    /// set (untagged / invalid-tagging / skipped), otherwise the tag-filtered playable files.
    /// This is what every file list shows — it can include skipped files (under the skipped
    /// filter), which playback then drops.
    var displaySequence: [PlaylistFile] {
        if let service = filterState.serviceFilter { return files(matching: service) }
        return tagFilteredPlayable
    }

    /// Files in playback order: `displaySequence` with skipped files removed, so advancing
    /// wraps around the playable set. Empty under the skipped filter (skipped files are never
    /// played), which is what guards the Play affordances against an empty triage state.
    var playbackSequence: [PlaylistFile] {
        displaySequence.filter { !$0.isSkipped }
    }

    /// Whether `playbackSequence` would contain any file — answered without building or
    /// sorting the sequence. It short-circuits on the first match, so the player's
    /// "no files" check stays cheap on large playlists instead of sorting every file
    /// each time the view re-renders.
    var hasPlaybackFiles: Bool {
        switch filterState.serviceFilter {
        case .untagged:       return files.contains { !$0.isSkipped && $0.taggingStatus == .untagged }
        case .invalidTagging: return files.contains { !$0.isSkipped && $0.taggingStatus == .invalid }
        case .skipped:        return false   // skipped files are never playable
        case nil:             break
        }
        guard !filterState.isEmpty else { return files.contains { !$0.isSkipped } }
        let selected = Set(filterState.selectedTags.map { $0.lowercased() })
        return files.contains { !$0.isSkipped && matchesFilter($0, selected: selected) }
    }

    /// Non-skipped files matching the persisted tag filter, sorted by `sortOrder`. The
    /// effective sequence when no triage filter is set.
    private var tagFilteredPlayable: [PlaylistFile] {
        let playable = files.filter { !$0.isSkipped }.sorted { $0.sortOrder < $1.sortOrder }
        guard !filterState.isEmpty else { return playable }

        let selected = Set(filterState.selectedTags.map { $0.lowercased() })
        return playable.filter { matchesFilter($0, selected: selected) }
    }

    /// Whether a file passes the persisted tag filter, given the pre-lowercased
    /// selected-tag set. Shared by `tagFilteredPlayable` and `hasPlaybackFiles`.
    private func matchesFilter(_ file: PlaylistFile, selected: Set<String>) -> Bool {
        let fileTags = Set(file.tags.map { $0.lowercased() })
        switch filterState.filterMode {
        case .and: return selected.isSubset(of: fileTags)
        case .or: return !selected.isDisjoint(with: fileTags)
        }
    }

    /// Files belonging to a triage filter, in display order. The one rule for "what each
    /// triage filter selects", shared by `displaySequence` and the notice-bar counts.
    func files(matching service: ServiceFilter) -> [PlaylistFile] {
        let byOrder: (PlaylistFile, PlaylistFile) -> Bool = { $0.sortOrder < $1.sortOrder }
        switch service {
        case .untagged:       return files.filter { !$0.isSkipped && $0.taggingStatus == .untagged }.sorted(by: byOrder)
        case .invalidTagging: return files.filter { !$0.isSkipped && $0.taggingStatus == .invalid }.sorted(by: byOrder)
        case .skipped:        return files.filter(\.isSkipped).sorted(by: byOrder)
        }
    }
}
