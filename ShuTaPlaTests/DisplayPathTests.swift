//
//  DisplayPathTests.swift
//  ShuTaPlaTests
//
//  The display form of a file's folder: the home folder as `~`, iCloud Drive by name.
//

import Testing
@testable import ShuTaPla

struct DisplayPathTests {

    private let home = "/Users/me"

    @Test(arguments: [
        ("/Users/me/Movies", "~/Movies"),
        ("/Users/me/Movies/", "~/Movies"),
        ("/Users/me", "~"),
        ("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Trips", "iCloud Drive/Trips"),
        ("/Users/me/Library/Mobile Documents/com~apple~CloudDocs", "iCloud Drive"),
        ("/Volumes/Disk/Movies", "/Volumes/Disk/Movies"),
        ("/Users/meg/Movies", "/Users/meg/Movies"),
        ("/", "/"),
    ])
    func abbreviated(path: String, expected: String) {
        #expect(DisplayPath.abbreviated(path, home: home) == expected)
    }

    /// A file at the playlist folder's top shows that folder.
    @Test func fileAtTopShowsPlaylistFolder() {
        #expect(DisplayPath.folder(ofFile: "clip.mp4", in: "/Users/me/Movies/", home: home) == "~/Movies")
    }

    /// A file in a subfolder shows the subfolder.
    @Test func fileInSubfolderShowsSubfolder() {
        #expect(DisplayPath.folder(ofFile: "2024/May/clip.mp4", in: "/Users/me/Movies", home: home) == "~/Movies/2024/May")
    }

    /// A playlist on the volume root keeps the root slash.
    @Test func fileOnVolumeRoot() {
        #expect(DisplayPath.folder(ofFile: "clip.mp4", in: "/", home: home) == "/")
        #expect(DisplayPath.folder(ofFile: "a/clip.mp4", in: "/", home: home) == "/a")
    }
}
