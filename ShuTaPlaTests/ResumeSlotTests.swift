//
//  ResumeSlotTests.swift
//  ShuTaPlaTests
//
//  Step 2 of per-filter resume positions: active-slot resolution and continuous capture.
//  `activeResumeSlot` maps a playlist's live `filterState` to the unfiltered slot, a matching
//  saved search, or none (ad-hoc / service filter); `captureResumePosition` mirrors a shuffle
//  position into that slot. The coordinator routes every natural file switch through the capture,
//  so the active filter's slot tracks playback. Exercised on an image playlist — the image engine
//  has no libmpv, so the teardown race (trap class 3) doesn't apply.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct ResumeSlotTests {

    // MARK: - Slot resolution & capture (pure)

    private func makePlaylist(_ filter: FilterState, searches: [SavedSearch] = []) -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        playlist.filterState = filter
        playlist.savedSearches = searches
        return playlist
    }

    @Test func unfilteredFilterSelectsUnfilteredSlot() {
        let playlist = makePlaylist(FilterState())
        #expect(playlist.activeResumeSlot == .unfiltered)

        playlist.captureResumePosition(5)
        #expect(playlist.unfilteredResumeSortOrder == 5)
        #expect(playlist.activeResumeSortOrder == 5)
    }

    @Test func matchingSavedSearchSelectsItsSlot() {
        let playlist = makePlaylist(
            FilterState(selectedTags: ["a"], filterMode: .and),
            searches: [SavedSearch(tags: ["a"], mode: .and)]
        )
        #expect(playlist.activeResumeSlot == .savedSearch(0))

        playlist.captureResumePosition(7)
        #expect(playlist.savedSearches[0].resumeSortOrder == 7)
        #expect(playlist.activeResumeSortOrder == 7)
        #expect(playlist.unfilteredResumeSortOrder == nil)   // the unfiltered slot is untouched
    }

    @Test func isCurrentFilterSavedOnlyForAMatchingSavedSearch() {
        let playlist = makePlaylist(FilterState(), searches: [SavedSearch(tags: ["a"], mode: .and)])

        playlist.filterState = FilterState(selectedTags: ["a"], filterMode: .and)
        #expect(playlist.isCurrentFilterSaved)                      // equals the stored search

        playlist.filterState = FilterState(selectedTags: ["b"], filterMode: .and)
        #expect(!playlist.isCurrentFilterSaved)                     // ad-hoc, no match

        playlist.filterState = FilterState()
        #expect(!playlist.isCurrentFilterSaved)                     // unfiltered earns no Save suppression
    }

    @Test func adHocFilterSelectsNoSlot() {
        // A tag filter with no matching saved search earns no slot, so capture writes nothing.
        let playlist = makePlaylist(FilterState(selectedTags: ["a"], filterMode: .and))
        #expect(playlist.activeResumeSlot == nil)
        #expect(playlist.activeResumeSortOrder == nil)

        playlist.captureResumePosition(7)
        #expect(playlist.unfilteredResumeSortOrder == nil)
    }

    @Test func serviceFilterSelectsNoSlot() {
        // A service filter overrides the tag side and has no slot — even alongside a saved search.
        let playlist = makePlaylist(
            FilterState(selectedTags: ["a"], filterMode: .and, serviceFilter: .untagged),
            searches: [SavedSearch(tags: ["a"], mode: .and, resumeSortOrder: 3)]
        )
        #expect(playlist.activeResumeSlot == nil)

        playlist.captureResumePosition(9)
        #expect(playlist.savedSearches[0].resumeSortOrder == 3)   // unchanged
    }

    // MARK: - Continuous capture through the coordinator

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// A temp directory of (empty) files plus a bookmark to it, so the coordinator's scoped access
    /// resolves. The image engine never decodes them — the assertions are on slot bookkeeping.
    private func makeFolder(_ files: [String]) throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeSlotTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeCoordinator(_ bookmarks: BookmarkService) -> PlaybackCoordinator {
        // Image-only here, but the mpv slots stay window-free in case the channel is probed.
        PlaybackCoordinator(
            folderAccess: ScopedFolderAccess(bookmarkService: bookmarks),
            makeVideoEngine: { try AudioPlaybackEngine() },
            makeAudioEngine: { try AudioPlaybackEngine() }
        )
    }

    @Test func playAndAdvanceMirrorIntoActiveSlot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = try makeFolder(["img0.jpg", "img1.jpg", "img2.jpg"])
        let playlist = makeImagePlaylist(tags: [], folder: folder, in: context)

        let coordinator = makeCoordinator(BookmarkService())
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
        playlist.filterState = FilterState(selectedTags: ["a"], filterMode: .and)   // no saved search → ad-hoc
        try? context.save()

        let coordinator = makeCoordinator(BookmarkService())
        defer { coordinator.shutdown() }

        coordinator.play(playlist)
        #expect(playlist.activeResumeSlot == nil)
        #expect(playlist.unfilteredResumeSortOrder == nil)   // nothing written for an ad-hoc filter
    }
}
