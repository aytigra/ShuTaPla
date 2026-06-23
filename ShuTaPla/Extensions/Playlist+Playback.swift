//
//  Playlist+Playback.swift
//  ShuTaPla
//
//  The order playback walks through a playlist and the order its file lists show. Both
//  derive from one rule — the playlist's *effective filter*: the triage filter when one is
//  set, otherwise the persisted tag filter. It lives on the model so the Manager, the
//  overlays, and the coordinator all reach the same sequence without duplicating the rule.
//
//  These derivations run on every render of a file list, so they read each file's
//  SwiftData-backed properties (`isSkipped`, `sortOrder`, `tags`, `taggingStatus`) exactly
//  once into plain locals and sort *those*. A SwiftData property read is far costlier than a
//  plain field access, and a comparison sort touches `sortOrder` O(n log n) times — reading it
//  once up front rather than on every comparison is what keeps a large playlist cheap to
//  re-derive instead of hitching the Manager on each scope/playlist switch.
//

import Foundation

extension Playlist {
    /// Files in display order under the effective filter: the triage filter's set when one is
    /// set (untagged / invalid-tagging / skipped), otherwise the tag-filtered playable files.
    /// This is what every file list shows — it can include skipped files (under the skipped
    /// filter), which playback then drops.
    var displaySequence: [PlaylistFile] {
        let service = filterState.serviceFilter
        // The lowercased selected-tag set, built once, only when a tag filter is the effective one.
        let selected: Set<String>? = (service == nil && !filterState.isEmpty)
            ? Set(filterState.selectedTags.map { $0.lowercased() })
            : nil
        let mode = filterState.filterMode

        // One pass: read each file's SwiftData fields once, decide membership, capture the
        // plain `sortOrder` alongside the file so the sort never reads through SwiftData.
        var kept: [(file: PlaylistFile, order: Int)] = []
        kept.reserveCapacity(files.count)
        for file in files {
            let skipped = file.isSkipped
            let keep: Bool
            if let service {
                switch service {
                case .untagged:       keep = !skipped && file.taggingStatus == .untagged
                case .invalidTagging: keep = !skipped && file.taggingStatus == .invalid
                case .skipped:        keep = skipped
                }
            } else if skipped {
                keep = false
            } else if let selected {
                keep = Self.tagsMatch(Set(file.tags.map { $0.lowercased() }), selected: selected, mode: mode)
            } else {
                keep = true
            }
            if keep { kept.append((file, file.sortOrder)) }
        }
        kept.sort { $0.order < $1.order }
        return kept.map(\.file)
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
        let mode = filterState.filterMode
        return files.contains { file in
            !file.isSkipped && Self.tagsMatch(Set(file.tags.map { $0.lowercased() }), selected: selected, mode: mode)
        }
    }

    /// The three triage counts — untagged / invalid-tagging / skipped — in a single pass, for
    /// the center's notice bar. One walk over `files` rather than three filtered passes, and no
    /// sort (the notices only show counts).
    var serviceFilterCounts: (untagged: Int, invalidTagging: Int, skipped: Int) {
        var untagged = 0, invalidTagging = 0, skipped = 0
        for file in files {
            if file.isSkipped { skipped += 1; continue }
            switch file.taggingStatus {
            case .untagged: untagged += 1
            case .invalid:  invalidTagging += 1
            case .valid:    break
            }
        }
        return (untagged, invalidTagging, skipped)
    }

    /// Whether a file's (lowercased) tag set satisfies the selected-tag filter. Shared by
    /// `displaySequence` and `hasPlaybackFiles` so the AND/OR rule lives in one place.
    private static func tagsMatch(_ fileTags: Set<String>, selected: Set<String>, mode: FilterMode) -> Bool {
        switch mode {
        case .and: return selected.isSubset(of: fileTags)
        case .or:  return !selected.isDisjoint(with: fileTags)
        }
    }
}
