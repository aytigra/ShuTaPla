//
//  Playlist+Sequence.swift
//  ShuTaPla
//
//  Ergonomic forwarders onto the store-side sequence derivation. The derivation itself lives on
//  `ModelContext` (it needs the context to fetch); a playlist reaches its own context to call it
//  and supplies the nil-context fallback once, in one place, so call sites read as
//  `playlist.playbackSequence` rather than repeating the `modelContext?.…(of: playlist) ?? default`
//  ceremony. Not Observation-tracked on their own — a view that re-derives on a mutation still
//  reads `appState.sequenceVersion` to invalidate.
//

import Foundation
import SwiftData

// The store derivation on `ModelContext` is main-actor-isolated (the module's default
// isolation), and every call site reads these on the main actor, so the forwarders are too.
@MainActor
extension Playlist {
    /// The identifiers playback walks, in order — `ModelContext.playbackSequence(of:)` against
    /// this playlist's own context. The lazy form every production caller holds: it resolves only
    /// the rows it needs via `model(for:)`, never the whole set. Empty when detached from a context.
    var playbackSequence: [PersistentIdentifier] {
        modelContext?.playbackSequence(of: self) ?? []
    }

    /// The files playback walks, in order — `ModelContext.playbackFiles(of:)` against this
    /// playlist's own context. Empty when the playlist is detached from a context.
    ///
    /// Test-only helper — must never be used in the app: it faults every row of the sequence into
    /// the context on the main actor. Production holds `playbackSequence` and resolves rows lazily.
    var playbackFiles: [PlaylistFile] {
        modelContext?.playbackFiles(of: self) ?? []
    }

    /// Whether playback would have any file under the effective filter, answered with a
    /// `fetchCount` rather than building the sequence.
    var hasPlaybackFiles: Bool {
        modelContext?.hasPlaybackFiles(in: self) ?? false
    }

    /// The total file count for the sidebar row badge, answered with a `fetchCount` — never
    /// faults the whole `files` relationship. Falls back to the in-memory relationship only
    /// when detached from a context.
    var fileCount: Int {
        modelContext?.fileCount(in: self) ?? files.count
    }

    /// The three triage counts — untagged / invalid-tagging / skipped — for the notice bar.
    var serviceFilterCounts: (untagged: Int, invalidTagging: Int, skipped: Int) {
        modelContext?.serviceFilterCounts(for: self) ?? (0, 0, 0)
    }
}
