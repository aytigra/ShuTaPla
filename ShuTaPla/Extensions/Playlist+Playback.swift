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
        return playable.filter { file in
            let fileTags = Set(file.tags.map { $0.lowercased() })
            switch filterState.filterMode {
            case .and: return selected.isSubset(of: fileTags)
            case .or: return !selected.isDisjoint(with: fileTags)
            }
        }
    }
}
