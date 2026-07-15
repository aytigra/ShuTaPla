//
//  CloudFileService.swift
//  ShuTaPla
//
//  The live iCloud/offline status feed. One `NSMetadataQuery` per live channel
//  (Visual, Audio) watches its playlist's folder and reports each file's ubiquitous
//  downloading state as it changes; the service maps every reported item back to its
//  `PlaylistFile` by relative path and writes `cloudStatus` — whose accessors are routed
//  through the model's `@Observable` registrar (see `PlaylistFile`), so the write re-renders
//  every view reading it and wakes the playback gate's arrival wait.
//
//  `NSMetadataQuery`/`NSMetadataItem` are non-`Sendable` and run-loop-bound, so the whole
//  service is `@MainActor`: queries are created, started, read, and stopped on the main
//  actor and never cross an isolation boundary. The classification-and-apply core is a
//  pure function over normalized `CloudStatusUpdate` values, so tests drive status
//  transitions through it without a live query or an iCloud account.
//

import Foundation
import Observation
import SwiftData

/// One normalized cloud-status observation: a file's path (relative to its playlist folder,
/// keyed the same way the scan records it) and the status the live feed reports for it.
nonisolated struct CloudStatusUpdate: Equatable, Sendable {
    let relativePath: String
    let status: CloudStatus
}

@MainActor
@Observable
final class CloudFileService {

    /// The independent live channels — the visual channel (video or image) and the audio channel
    /// of playback, plus the Manager preview's own watch — so playlists in different folders (and a
    /// peek outside them) can each stay live at once.
    enum Channel: Hashable { case visual, audio, preview }

    /// One running folder watch: the query, the playlist whose files it writes onto, and its
    /// observer tokens. Each token's closure captures its own folder URL for relative-path keying.
    private final class Monitor {
        let query: NSMetadataQuery
        weak var playlist: Playlist?
        var tokens: [NSObjectProtocol] = []

        init(query: NSMetadataQuery, playlist: Playlist) {
            self.query = query
            self.playlist = playlist
        }
    }

    private var monitors: [Channel: Monitor] = [:]

    /// Issues the actual ubiquitous-download request for a resolved file URL. Production wires it
    /// to `FileManager`; tests inject a capture so they assert requests without touching iCloud.
    private let requester: (URL) throws -> Void

    init(requester: @escaping (URL) throws -> Void = {
        try FileManager.default.startDownloadingUbiquitousItem(at: $0)
    }) {
        self.requester = requester
    }

    // MARK: - Live query lifecycle

    /// Starts (or rescopes) `channel`'s query to `playlist`'s folder. Replacing an existing
    /// monitor on the channel tears the old one down first, so a channel never runs two queries.
    func beginMonitoring(_ playlist: Playlist, folderURL: URL, on channel: Channel) {
        endMonitoring(on: channel)

        let query = NSMetadataQuery()
        query.searchScopes = [folderURL]
        query.valueListAttributes = [
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemIsDownloadingKey,
        ]
        // Scope already restricts to the folder; match every file and let the apply core's
        // path-keying keep only the ones this playlist actually holds.
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")

        let monitor = Monitor(query: query, playlist: playlist)
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] note in
                let updates = Self.statusUpdates(from: note, under: folderURL)
                MainActor.assumeIsolated { self?.absorb(updates, on: channel) }
            }
            monitor.tokens.append(token)
        }
        monitors[channel] = monitor
        query.start()
    }

    /// Normalizes a query notification to `Sendable` updates on the main run loop where it fires, so
    /// nothing run-loop-bound (`NSMetadataItem`/`NSMetadataQuery`) crosses into the actor. A
    /// `DidUpdate` folds only its changed + added items — so a frequent progress tick classifies just
    /// those; a `DidFinishGathering` (no delta keys) reads the query's full results once under a
    /// stable snapshot, the one-time initial gather.
    private nonisolated static func statusUpdates(from note: Notification, under folderURL: URL) -> [CloudStatusUpdate] {
        let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]
        let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]
        let items: [NSMetadataItem]
        if changed != nil || added != nil {
            items = (changed ?? []) + (added ?? [])
        } else if let query = note.object as? NSMetadataQuery {
            query.disableUpdates()
            defer { query.enableUpdates() }
            items = query.results as? [NSMetadataItem] ?? []
        } else {
            items = []
        }
        return items.compactMap { item in
            (item.value(forAttribute: NSMetadataItemURLKey) as? URL).map { url in
                CloudStatusUpdate(
                    relativePath: FileSystemService.relativePath(of: url, under: folderURL),
                    status: CloudStatus.from(item)
                )
            }
        }
    }

    /// Stops and discards `channel`'s query, if any.
    func endMonitoring(on channel: Channel) {
        guard let monitor = monitors.removeValue(forKey: channel) else { return }
        monitor.query.stop()
        monitor.tokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Resolves a channel's reported paths to their models through a scoped fetch — never
    /// `playlist.files`, so the whole relationship is never faulted on the main actor — and folds the
    /// statuses on. Fed the already-normalized `Sendable` updates by the notification observer; tests
    /// drive it directly to simulate a channel's feed reporting arrival.
    func absorb(_ updates: [CloudStatusUpdate], on channel: Channel) {
        guard let monitor = monitors[channel], let playlist = monitor.playlist,
              let context = playlist.modelContext else { return }
        apply(updates, to: context.files(in: playlist, atRelativePaths: Set(updates.map(\.relativePath))))
    }

    // MARK: - On-demand download

    /// Requests that the file at `url` be pulled down from iCloud, returning immediately — the live
    /// feed reports the resulting `.downloading` → `.local` transition. The one entry point for both
    /// on-demand playback and prefetch. The caller resolves the URL under the playlist folder's live
    /// scoped-access session (the coordinator's `url(for:)`), matching how `beginMonitoring` is
    /// handed its folder URL; a failed request is a silent no-op.
    func requestDownload(at url: URL) {
        try? requester(url)
    }

    // MARK: - Apply core (pure, no live query)

    /// Writes each update's status onto the file it names, matched by relative path; files no
    /// update mentions keep their current status. The seam the tests drive: a status event flips
    /// the matching model and leaves the rest untouched.
    func apply(_ updates: [CloudStatusUpdate], to files: [PlaylistFile]) {
        guard updates.isNotEmpty else { return }
        let byPath = Dictionary(files.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        for update in updates {
            byPath[update.relativePath]?.cloudStatus = update.status
        }
    }
}
