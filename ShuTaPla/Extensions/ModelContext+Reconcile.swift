//
//  ModelContext+Reconcile.swift
//  ShuTaPla
//
//  Projecting a folder scan onto a playlist's `PlaylistFile` rows: build the absent ones,
//  prune the vanished ones, and mirror each surviving file's filename-derived tags onto the
//  `Tag` relationship and `taggingStatusCode` index the filters query. The on-disk filename is
//  the source of truth; those columns are a denormalized index this keeps in step.
//
//  `nonisolated`, on `ModelContext`, so it runs against whichever context its caller holds:
//  the background `PlaylistScanActor`'s context (the Update path, off the main actor) and the
//  main context (initial creation in `AppState.makePlaylist`). Pure store work, no main-actor
//  state — the caller's executor carries it.
//

import Foundation
import SwiftData

/// What a reconcile changed, handed back across the actor boundary (so it is `Sendable`: only
/// value types). `removedFileIDs` are the app ids of the pruned files, so the main actor can
/// drop any pending UI reference to them. Everything derived — files, tags, and `tagFrequency` —
/// is written and saved on the reconciling context, so nothing else needs to cross the boundary.
nonisolated struct ScanReconcileResult: Sendable, Equatable {
    let removedFileIDs: [UUID]
    let changed: Bool

    static let unchanged = ScanReconcileResult(removedFileIDs: [], changed: false)
}

nonisolated extension ModelContext {

    /// Reconciles `playlist`'s files against `current` (every file now on disk, each with its
    /// derived tags): prunes files no longer present, builds naked rows for the new ones, writes
    /// each surviving file's diverged tag fields, and rebuilds the playlist's `tagFrequency`. Saves
    /// nothing: the caller saves (and, off-main, cleans orphan tags) so the store-side surfaces
    /// re-derive from the committed state. Returns what changed.
    func reconcile(_ current: [ScannedFile], into playlist: Playlist) -> ScanReconcileResult {
        let currentPaths = Set(current.map(\.relativePath))
        let toRemove = playlist.files.filter { !currentPaths.contains($0.relativePath) }
        let removedIDs = Set(toRemove.map(\.id))
        // Derive the next sort order from the files that survive this scan, not the post-detach
        // set, so a still-counted to-be-removed file can't lend its `sortOrder` to a new file and
        // collide, breaking stable playback ordering.
        var nextOrder = (playlist.files.filter { !removedIDs.contains($0.id) }.map(\.sortOrder).max() ?? -1) + 1
        for file in toRemove {
            file.playlist = nil  // detach so playlist.files updates synchronously
            delete(file)
        }

        // Index the survivors by relative path so each scanned file maps to its model.
        var byPath: [String: PlaylistFile] = [:]
        for file in playlist.files { byPath[file.relativePath] = file }

        // Reconcile every file now on disk in one pass: build a naked row for the absent ones
        // (appended after the survivors), then derive each file's filename tags onto the index
        // the filters query — only where it diverges, so an unchanged playlist writes nothing
        // and never fetches. New rows and re-derivations share one lazily-primed `Tag` cache.
        var changed = !toRemove.isEmpty
        var tagCache: [String: Tag]?
        for scanned in current {
            let file: PlaylistFile
            if let existing = byPath[scanned.relativePath] {
                file = existing
            } else {
                file = makeFile(from: scanned, in: playlist, sortOrder: nextOrder)
                byPath[scanned.relativePath] = file
                nextOrder += 1
                changed = true
            }
            if writeDerivedFields(scanned, onto: file, tagCache: &tagCache) { changed = true }
        }

        guard changed else { return .unchanged }
        rebuildTagFrequency(of: playlist)
        return ScanReconcileResult(removedFileIDs: Array(removedIDs), changed: true)
    }

    /// Builds and inserts one `PlaylistFile` from a scanned file at `sortOrder` — a naked row:
    /// relative path, name, skip flag, sort order, cloud status. A file whose media type differs
    /// from the playlist's is marked skipped (kept for the skipped-files filter, never played).
    /// Its tags are written separately by `writeDerivedFields`, so a freshly built row carries
    /// the default (untagged, no tags) until that runs.
    @discardableResult
    func makeFile(from scanned: ScannedFile, in playlist: Playlist, sortOrder: Int) -> PlaylistFile {
        let file = PlaylistFile(
            relativePath: scanned.relativePath,
            fileName: scanned.fileName,
            isSkipped: scanned.mediaType != playlist.mediaType,
            sortOrder: sortOrder
        )
        file.cloudStatus = scanned.cloudStatus
        file.playlist = playlist
        insert(file)
        return file
    }

    /// Writes a scanned file's filename-derived tag fields onto its model, but only where they
    /// diverge from what's stored — the single site that projects a parsed filename onto the
    /// `Tag` relationship and `taggingStatusCode` the tag and triage filters query store-side.
    /// A file with no divergence is left untouched (a clean playlist writes nothing, and never
    /// fetches), while a migration-emptied or renamed file gains its tags. The shared `Tag`s
    /// resolve through one `tagCache`, primed lazily on the first divergence and reused across
    /// the batch. Returns whether anything changed.
    @discardableResult
    func writeDerivedFields(
        _ scanned: ScannedFile, onto file: PlaylistFile, tagCache: inout [String: Tag]?
    ) -> Bool {
        var changed = false
        if file.taggingStatusCode != scanned.taggingStatus.code {
            file.taggingStatus = scanned.taggingStatus
            changed = true
        }
        let desired = Set(TagParser.dedupe(scanned.tagNames).map { $0.lowercased() })
        if desired != Set(file.tags.map(\.normalizedName)) {
            var cache = tagCache ?? tagsByNormalizedName()
            file.tags = tags(named: scanned.tagNames, cache: &cache)
            tagCache = cache
            changed = true
        }
        return changed
    }

    /// The per-playlist tag usage counts from its playable files — what the filter dropdown lists.
    func computeTagFrequency(of playlist: Playlist) -> [String: Int] {
        var frequency: [String: Int] = [:]
        for file in playlist.files where !file.isSkipped {
            for tag in file.tags { frequency[tag.name, default: 0] += 1 }
        }
        return frequency
    }

    /// Recomputes and stores a playlist's tag-frequency cache — the main-actor convenience for
    /// paths that mutate tags on the main context (creation, rename, delete).
    func rebuildTagFrequency(of playlist: Playlist) {
        playlist.tagFrequency = computeTagFrequency(of: playlist)
    }

    /// Re-reads `playlist` so the held instance reflects writes another context committed: a sibling
    /// save is not merged into a registered object, leaving its attributes (`tagFrequency`) and
    /// relationships (`files`) stale until refaulted. Fetching the row merges the committed state
    /// into the same registered instance in place — no save, nothing discarded.
    func refreshFromStore(_ playlist: Playlist) {
        let id = playlist.id
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        _ = try? fetch(descriptor)
    }

    /// Deletes every `Tag` no file references any longer — a tag dropped from every filename it
    /// once appeared in. `Tag` is shared many-to-many across playlists, so a tag is removed only
    /// when its `files` is globally empty; one another playlist's files still carry is kept. Run
    /// *after* the save: `delete(model:where:)` is a batched store delete that sees saved rows,
    /// not pending changes, so the `file.tags` reassignments must already be persisted for it to
    /// find the now-orphaned tags. It bypasses in-memory inverse maintenance, harmless here
    /// because the targets reference no files.
    func cleanupOrphanTags() {
        try? delete(model: Tag.self, where: #Predicate { $0.files.isEmpty })
    }
}
