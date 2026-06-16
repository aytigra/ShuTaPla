//
//  Playlist+Playback.swift
//  ShuTaPla
//
//  The order playback walks through a playlist: its playable files, narrowed by
//  the persisted tag filter, in `sortOrder`. This is the sequence the coordinator
//  advances over (and the Manager file list shows when no service filter is on),
//  so it lives on the model where both can reach it without duplicating the rule.
//

import Foundation

extension Playlist {
    /// Files in playback order: non-skipped files matching the persisted tag
    /// filter, sorted by `sortOrder`. Never reshuffled by playback — advancing
    /// wraps around this fixed sequence.
    var playbackSequence: [PlaylistFile] {
        let playable = files.filter { !$0.isSkipped }.sorted { $0.sortOrder < $1.sortOrder }
        guard !filterState.isEmpty else { return playable }

        let selected = Set(filterState.selectedTags.map { $0.lowercased() })
        return playable.filter { matchesFilter($0, selected: selected) }
    }

    /// Whether `playbackSequence` would contain any file — answered without building or
    /// sorting the sequence. It short-circuits on the first match, so the player's
    /// "no files" check stays cheap on large playlists instead of sorting every file
    /// each time the view re-renders.
    var hasPlaybackFiles: Bool {
        guard !filterState.isEmpty else { return files.contains { !$0.isSkipped } }
        let selected = Set(filterState.selectedTags.map { $0.lowercased() })
        return files.contains { !$0.isSkipped && matchesFilter($0, selected: selected) }
    }

    /// Whether a file passes the persisted tag filter, given the pre-lowercased
    /// selected-tag set. Shared by `playbackSequence` and `hasPlaybackFiles`.
    private func matchesFilter(_ file: PlaylistFile, selected: Set<String>) -> Bool {
        let fileTags = Set(file.tags.map { $0.lowercased() })
        switch filterState.filterMode {
        case .and: return selected.isSubset(of: fileTags)
        case .or: return !selected.isDisjoint(with: fileTags)
        }
    }

    /// Files belonging to a runtime service filter, in display order. The one rule
    /// for "what each service filter selects", shared by the Manager file list (when
    /// the filter is active) and the notice-bar counts.
    func files(matching service: ServiceFilter) -> [PlaylistFile] {
        let byOrder: (PlaylistFile, PlaylistFile) -> Bool = { $0.sortOrder < $1.sortOrder }
        switch service {
        case .untagged:       return files.filter { !$0.isSkipped && $0.taggingStatus == .untagged }.sorted(by: byOrder)
        case .invalidTagging: return files.filter { !$0.isSkipped && $0.taggingStatus == .invalid }.sorted(by: byOrder)
        case .skipped:        return files.filter(\.isSkipped).sorted(by: byOrder)
        }
    }
}
