//
//  TagModelTests.swift
//  ShuTaPlaTests
//
//  Task 17 — the normalized `Tag` relationship: find-or-create dedup by normalized name,
//  case-insensitive resolution with first-seen casing, sharing across files, and the
//  scalar `taggingStatus` discriminator that backs the predicate-queryable column.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct TagModelTests {

    /// `Testing` also exports a `Tag`; this disambiguates to the app model in this file.
    private typealias Tag = ShuTaPla.Tag

    /// Holds the container for the whole body so the context never orphans (trap class 1).
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func tagNamedFindsOrCreatesDedupedByNormalizedName() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let first = context.tag(named: "Beach")
        let second = context.tag(named: "beach")   // same tag, different casing

        #expect(first.persistentModelID == second.persistentModelID)
        #expect(try context.fetch(FetchDescriptor<Tag>()).count == 1)
        #expect(first.normalizedName == "beach")
        #expect(first.name == "Beach")   // first-seen casing is kept
    }

    @Test func tagsNamedDedupesCaseInsensitivelyKeepingFirstCasing() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let tags = context.tags(named: ["Beach", "beach", "Sunny"])

        #expect(tags.map(\.name) == ["Beach", "Sunny"])
        #expect(try context.fetch(FetchDescriptor<Tag>()).count == 2)
    }

    @Test func tagsAreSharedAcrossFiles() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/p", mediaType: .image)
        context.insert(playlist)

        let a = PlaylistFile(relativePath: "a.jpg", fileName: "a.jpg", taggingStatus: .valid, sortOrder: 0)
        let b = PlaylistFile(relativePath: "b.jpg", fileName: "b.jpg", taggingStatus: .valid, sortOrder: 1)
        a.playlist = playlist; b.playlist = playlist
        context.insert(a); context.insert(b)
        a.tags = context.tags(named: ["beach"])
        b.tags = context.tags(named: ["beach"])
        try context.save()

        // One shared Tag row, carrying both files via the inverse.
        let tags = try context.fetch(FetchDescriptor<Tag>())
        #expect(tags.count == 1)
        #expect(Set(tags.first?.files.map(\.fileName) ?? []) == ["a.jpg", "b.jpg"])
        #expect(a.tags.map(\.name) == ["beach"])
    }

    @Test(arguments: [TaggingStatus.valid, .untagged, .invalid])
    func taggingStatusRoundTripsThroughScalar(_ status: TaggingStatus) {
        let file = PlaylistFile(relativePath: "f.mp4", fileName: "f.mp4")
        file.taggingStatus = status
        #expect(file.taggingStatusCode == status.code)
        #expect(file.taggingStatus == status)
        #expect(TaggingStatus(code: status.code) == status)
    }
}
