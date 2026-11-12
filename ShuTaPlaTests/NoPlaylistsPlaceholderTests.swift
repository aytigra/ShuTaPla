//
//  NoPlaylistsPlaceholderTests.swift
//  ShuTaPlaTests
//
//  The empty-playlist placeholder's wording and symbol for one media type and for several.
//

import Testing
@testable import ShuTaPla

@MainActor
struct NoPlaylistsPlaceholderTests {

    @Test func oneTypeIsNamedWithItsOwnSymbol() {
        let placeholder = NoPlaylistsPlaceholder(mediaTypes: [.video])
        #expect(placeholder.title == "No Video Playlists")
        #expect(placeholder.message == "Add a folder of videos.")
        #expect(placeholder.systemImage == MediaType.video.systemImage)
    }

    @Test func severalTypesAreAllNamed() {
        let placeholder = NoPlaylistsPlaceholder(mediaTypes: [.video, .image])
        #expect(placeholder.title == "No Video or Image Playlists")
        #expect(placeholder.message == "Add a folder of videos or images.")
        #expect(placeholder.systemImage == "rectangle.stack")
    }
}
