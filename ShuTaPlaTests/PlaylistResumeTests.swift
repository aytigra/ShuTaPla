//
//  PlaylistResumeTests.swift
//  ShuTaPlaTests
//
//  Per-filter resume positions: which slot the live filter selects, and the continuous capture that
//  keeps it current as playback moves. The coordinator routes every natural file switch through the
//  capture, so the active filter's slot tracks playback. Exercised on an image playlist — the image
//  engine has no libmpv, so the teardown race (trap class 3) doesn't apply.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct PlaylistResumeTests {

    // MARK: - Slot resolution & capture

    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        return try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A playlist with an optional applied filter, optionally saved over.
    private func makePlaylist(
        in context: ModelContext, tags: [String] = [], saved: String? = nil,
        service: ServiceFilter? = nil, resumeSortOrder: Int? = nil
    ) -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)
        playlist.serviceFilter = service
        if tags.isNotEmpty {
            let filter = TagFilter()
            filter.mustHaveAll = tags
            context.insert(filter)
            playlist.currentFilter = filter
            if let saved {
                let search = SavedSearch(name: saved, resumeSortOrder: resumeSortOrder)
                context.insert(search)
                search.playlist = playlist
                search.filter = filter
            }
        }
        return playlist
    }

    @Test func anUnfilteredPlaylistUsesTheUnfilteredSlot() throws {
        let container = try makeContainer()
        let playlist = makePlaylist(in: container.mainContext)

        playlist.captureResumePosition(5)
        #expect(playlist.unfilteredResumeSortOrder == 5)
        #expect(playlist.activeResumeSortOrder == 5)
    }

    @Test func anActiveSavedSearchUsesItsOwnSlot() throws {
        let container = try makeContainer()
        let playlist = makePlaylist(in: container.mainContext, tags: ["a"], saved: "A")

        playlist.captureResumePosition(7)
        #expect(playlist.currentFilter?.savedSearch?.resumeSortOrder == 7)
        #expect(playlist.activeResumeSortOrder == 7)
        #expect(playlist.unfilteredResumeSortOrder == nil)   // the unfiltered slot is untouched
    }

    @Test func anAdHocFilterEarnsNoSlot() throws {
        let container = try makeContainer()
        // A filter no search was saved over: you never switch *into* ad-hoc, so it needs no slot.
        let playlist = makePlaylist(in: container.mainContext, tags: ["a"])
        #expect(playlist.activeResumeSortOrder == nil)

        playlist.captureResumePosition(7)
        #expect(playlist.activeResumeSortOrder == nil)
        #expect(playlist.unfilteredResumeSortOrder == nil)   // and writes nothing elsewhere
    }

    /// The service-filter guard has to answer "no slot" rather than inheriting whatever the tag
    /// filter underneath would answer — the search's slot with one set, the unfiltered slot with
    /// none. Three different answers, separated only by the guard, so both directions are pinned.
    @Test func aServiceFilterEarnsNoSlotOverASavedSearch() throws {
        let container = try makeContainer()
        let playlist = makePlaylist(in: container.mainContext, tags: ["a"], saved: "A",
                                    service: .untagged, resumeSortOrder: 3)
        #expect(playlist.activeResumeSortOrder == nil)

        playlist.captureResumePosition(9)
        #expect(playlist.currentFilter?.savedSearch?.resumeSortOrder == 3)   // unchanged
    }

    @Test func aServiceFilterEarnsNoSlotOverNoTagFilter() throws {
        let container = try makeContainer()
        let playlist = makePlaylist(in: container.mainContext, service: .invalidTagging)
        playlist.unfilteredResumeSortOrder = 2
        #expect(playlist.activeResumeSortOrder == nil)

        playlist.captureResumePosition(9)
        #expect(playlist.unfilteredResumeSortOrder == 2)   // unchanged
    }

    @Test func reshuffleVoidsEverySlot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = makePlaylist(in: context, tags: ["a"], saved: "A", resumeSortOrder: 3)
        playlist.unfilteredResumeSortOrder = 5

        let parked = SavedSearch(name: "Parked", listOrder: 1, resumeSortOrder: 8)
        context.insert(parked)
        parked.playlist = playlist

        playlist.clearResumePositions()

        #expect(playlist.unfilteredResumeSortOrder == nil)
        #expect(playlist.savedSearches.allSatisfy { $0.resumeSortOrder == nil })
    }

    // MARK: - Continuous capture through the coordinator

    /// A temp directory of (empty) files plus a bookmark to it, so the coordinator's scoped access
    /// resolves. The image engine never decodes them — the assertions are on slot bookkeeping.
    private func makeFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistResumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files { try Data().write(to: url.appending(path: name)) }
        return (url, try BookmarkService.makeBookmark(for: url))
    }

    private func makeImagePlaylist(
        tags: [String], folder: (url: URL, bookmark: Data), in context: ModelContext
    ) -> Playlist {
        let playlist = Playlist(
            name: "Images", folderBookmark: folder.bookmark,
            folderPath: folder.url.path(percentEncoded: false), mediaType: .image
        )
        context.insert(playlist)
        for index in 0..<3 {
            insertFile("img\(index).jpg", tags: tags, status: tags.isEmpty ? .untagged : .valid,
                       order: index, to: playlist, in: context)
        }
        try? context.save()
        return playlist
    }

    private func makeCoordinator(_ bookmarks: BookmarkService, _ context: ModelContext) -> PlaybackCoordinator {
        // Image-only here, but the mpv slots stay window-free in case the channel is probed.
        PlaybackCoordinator(
            folderAccess: ScopedFolderAccess(bookmarkService: bookmarks),
            sequences: PlaybackSequences(modelContext: context),
            makeVideoEngine: { try AudioPlaybackEngine() },
            makeAudioEngine: { try AudioPlaybackEngine() }
        )
    }

    @Test func playAndAdvanceMirrorIntoActiveSlot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["img0.jpg", "img1.jpg", "img2.jpg"])
        let playlist = makeImagePlaylist(tags: [], folder: folder, in: context)

        let coordinator = makeCoordinator(BookmarkService(), context)
        defer { coordinator.shutdown() }

        coordinator.play(playlist)
        #expect(playlist.unfilteredResumeSortOrder == 0)   // captured the start file's position

        coordinator.next(playlist)
        #expect(playlist.unfilteredResumeSortOrder == 1)   // advance mirrors the new file's position
    }

    @Test func adHocFilterCapturesNothingOnPlay() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["img0.jpg", "img1.jpg", "img2.jpg"])
        // Files tagged so the ad-hoc ["a"] filter has a non-empty sequence to start from.
        let playlist = makeImagePlaylist(tags: ["a"], folder: folder, in: context)
        let filter = TagFilter()
        filter.mustHaveAll = ["a"]
        context.insert(filter)
        playlist.currentFilter = filter   // no saved search → ad-hoc
        try context.save()

        let coordinator = makeCoordinator(BookmarkService(), context)
        defer { coordinator.shutdown() }

        coordinator.play(playlist)
        #expect(playlist.activeResumeSortOrder == nil)
        #expect(playlist.unfilteredResumeSortOrder == nil)   // nothing written for an ad-hoc filter
    }
}
