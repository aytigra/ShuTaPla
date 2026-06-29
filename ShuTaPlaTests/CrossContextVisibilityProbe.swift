//
//  CrossContextVisibilityProbe.swift
//  ShuTaPlaTests
//
//  Foundational experiment for the background-scan derivation (Step 2): a second
//  ModelContext on the same container writes derived tag fields and saves; does the
//  main context's store-side fetch (and `model(for:)`) then see those writes? The
//  whole Step-2 handoff ("background writes → save → main bumps version → views
//  re-fetch") rests on this, so it is proven before the actor is built on top of it.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct CrossContextVisibilityProbe {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A second context derives tags/status onto an existing file and saves. The main context
    /// should then see the change both store-side (the filter predicate) and through `model(for:)`.
    @Test func secondContextWriteVisibleToMainContext() throws {
        let container = try makeContainer()
        let main = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp", mediaType: .image)
        main.insert(playlist)
        let file = PlaylistFile(relativePath: "a.jpg", fileName: "[beach] a.jpg", sortOrder: 0)
        file.playlist = playlist
        main.insert(file)
        try main.save()
        let fileID = file.persistentModelID

        // Background context: write the derived tag + status and save.
        let bg = ModelContext(container)
        guard let bgFile = bg.model(for: fileID) as? PlaylistFile else {
            Issue.record("background context could not resolve the file")
            return
        }
        let tag = Tag(name: "beach", normalizedName: "beach")
        bg.insert(tag)
        bgFile.tags = [tag]
        bgFile.taggingStatus = .valid
        try bg.save()

        // Store-side fetch from the main context (ignoring its own pending changes):
        // does it see the status the background context committed?
        let validCode = TaggingStatus.valid.code
        var descriptor = FetchDescriptor<PlaylistFile>(
            predicate: #Predicate { $0.taggingStatusCode == validCode }
        )
        descriptor.includePendingChanges = false
        let matches = (try? main.fetch(descriptor)) ?? []
        #expect(matches.count == 1)

        // And does resolving the same id through the main context reflect the new relationship,
        // or does it hand back a stale registered object?
        let resolved = main.model(for: fileID) as? PlaylistFile
        #expect(resolved?.taggingStatus == .valid)
        #expect(resolved?.tags.count == 1)
    }

    /// A second context deletes one file and adds another, then saves. Two facts the Update path
    /// leans on: (a) a store-side fetch reflects the new set (the UI's `displaySequence` path, which
    /// the version bump re-derives), and (b) a held reference to the deleted file still surrenders its
    /// stored `id` for UI cleanup (pruning `pendingManagerDelete`) without trapping — `model(for:)`
    /// keeps a stale-but-live object for a cross-context delete. (The held *relationship* going stale
    /// until refaulted is covered by `refreshFromStoreRefaultsHeldPlaylistAfterSiblingSave`.)
    @Test func secondContextDeleteAndAddVisibleToMainContext() throws {
        let container = try makeContainer()
        let main = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp", mediaType: .image)
        main.insert(playlist)
        let file = PlaylistFile(relativePath: "a.jpg", fileName: "a.jpg", sortOrder: 0)
        file.playlist = playlist
        main.insert(file)
        try main.save()
        let fileID = file.persistentModelID
        let playlistID = playlist.persistentModelID
        let storedUUID = file.id

        // Hold a main-context reference (as pendingManagerDelete would), then mutate elsewhere.
        let mainRef = main.model(for: fileID) as? PlaylistFile

        let bg = ModelContext(container)
        let bgPlaylist = bg.model(for: playlistID) as? Playlist
        if let bgFile = bg.model(for: fileID) as? PlaylistFile {
            bgFile.playlist = nil
            bg.delete(bgFile)
        }
        let added = PlaylistFile(relativePath: "b.jpg", fileName: "b.jpg", sortOrder: 1)
        added.playlist = bgPlaylist
        bg.insert(added)
        try bg.save()

        // (a) store-side fetch reflects the new set.
        var descriptor = FetchDescriptor<PlaylistFile>(sortBy: [SortDescriptor(\.sortOrder)])
        descriptor.includePendingChanges = false
        let remaining = (try? main.fetch(descriptor)) ?? []
        #expect(remaining.map(\.relativePath) == ["b.jpg"])

        // (b) the held reference still surrenders its stored UUID without trapping.
        #expect(mainRef?.id == storedUUID)
    }

    /// The fact the Update path's main-side tail rests on: a sibling-context save is not merged into
    /// a registered (held) object — its scalar (`tagFrequency`) and relationship (`files`) go stale —
    /// but `refreshFromStore` (a fetch of the row) refaults that same instance in place to the
    /// committed state. So `applyScanResult` can refault the held playlist and the UI keeps reading
    /// `playlist.tagFrequency` / `playlist.files` directly.
    @Test func refreshFromStoreRefaultsHeldPlaylistAfterSiblingSave() throws {
        let container = try makeContainer()
        let main = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp", mediaType: .image)
        playlist.tagFrequency = ["old": 1]
        main.insert(playlist)
        let seed = PlaylistFile(relativePath: "a.jpg", fileName: "a.jpg", sortOrder: 0)
        seed.playlist = playlist
        main.insert(seed)
        try main.save()
        let pid = playlist.persistentModelID

        // Hold the playlist on main (as the UI does) and fault in both fields.
        let mainPlaylist = main.model(for: pid) as? Playlist
        _ = mainPlaylist?.tagFrequency
        _ = mainPlaylist?.files.count

        // A background context rewrites the scalar and reshapes the relationship, then saves.
        let bg = ModelContext(container)
        if let bgPlaylist = bg.model(for: pid) as? Playlist {
            bgPlaylist.tagFrequency = ["new": 2]
            if let bgFile = bgPlaylist.files.first { bgFile.playlist = nil; bg.delete(bgFile) }
            let added = PlaylistFile(relativePath: "b.jpg", fileName: "b.jpg", sortOrder: 1)
            added.playlist = bgPlaylist
            bg.insert(added)
        }
        try bg.save()

        // The held instance is still stale until refaulted...
        #expect(mainPlaylist?.tagFrequency == ["old": 1])
        #expect(mainPlaylist?.files.map(\.relativePath) == ["a.jpg"])

        // ...and `refreshFromStore` brings the same held instance up to the committed state in place.
        if let mainPlaylist { main.refreshFromStore(mainPlaylist) }
        #expect(mainPlaylist?.tagFrequency == ["new": 2])
        #expect(mainPlaylist?.files.map(\.relativePath) == ["b.jpg"])
    }

    /// The production query shape: a store-side fetch *filtered by the playlist relationship*
    /// (`$0.playlist?.persistentModelID == pid`) — the predicate `displaySequence` uses. A file the
    /// background context inserts with its `playlist` relationship set must show up through it, or
    /// the whole "background writes → main re-fetches" handoff fails to surface added files.
    @Test func secondContextAddVisibleThroughPlaylistFilteredFetch() throws {
        let container = try makeContainer()
        let main = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp", mediaType: .image)
        main.insert(playlist)
        let a = PlaylistFile(relativePath: "a.jpg", fileName: "a.jpg", sortOrder: 0)
        a.playlist = playlist
        main.insert(a)
        try main.save()
        let playlistID = playlist.persistentModelID
        let appID = playlist.id

        let bg = ModelContext(container)
        var d = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == appID })
        d.fetchLimit = 1
        let bgPlaylist = try bg.fetch(d).first
        let b = PlaylistFile(relativePath: "b.jpg", fileName: "b.jpg", sortOrder: 1)
        b.playlist = bgPlaylist
        bg.insert(b)
        try bg.save()

        var fetch = FetchDescriptor<PlaylistFile>(
            predicate: #Predicate { $0.playlist?.persistentModelID == playlistID },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        fetch.includePendingChanges = false
        let names = (try? main.fetch(fetch))?.map(\.fileName) ?? []
        #expect(names == ["a.jpg", "b.jpg"])
    }

    /// The actor in isolation: seed a.mp4/b.mp4 on main, reconcile to {b.mp4, c.mp4}, then a
    /// main-context store-side fetch should show the survivor b and the new c (a pruned). The actor
    /// owns the whole derived write (no main-side save); after the main actor refaults the held
    /// playlist — as `applyScanResult` does — its `tagFrequency` reflects the rebuilt counts from c's tag.
    @Test func scanActorReconcilePersistsAddsAndRemovesAcrossContexts() async throws {
        let container = try makeContainer()
        let main = container.mainContext

        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp", mediaType: .video)
        main.insert(playlist)
        for (i, name) in ["a.mp4", "b.mp4"].enumerated() {
            let f = PlaylistFile(relativePath: name, fileName: name, sortOrder: i)
            f.playlist = playlist
            main.insert(f)
        }
        try main.save()
        let appID = playlist.id
        let pid = playlist.persistentModelID

        func scanned(_ name: String, tags: [String] = []) -> ScannedFile {
            ScannedFile(relativePath: name, fileName: name, mediaType: .video, cloudStatus: .local,
                        tagNames: tags, taggingStatus: tags.isEmpty ? .untagged : .valid)
        }
        let actor = PlaylistScanActor(modelContainer: container)
        let result = await actor.reconcile(
            [scanned("b.mp4"), scanned("c.mp4", tags: ["beach"])],
            playlistID: appID
        )
        #expect(result.changed)

        var fetch = FetchDescriptor<PlaylistFile>(
            predicate: #Predicate { $0.playlist?.persistentModelID == pid },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        fetch.includePendingChanges = false
        let names = (try? main.fetch(fetch))?.map(\.fileName) ?? []
        #expect(names == ["b.mp4", "c.mp4"])
        // The actor rebuilt the counts on its own context; refaulting the held playlist surfaces them.
        main.refreshFromStore(playlist)
        #expect(playlist.tagFrequency["beach"] == 1)
    }
}
