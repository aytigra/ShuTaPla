//
//  HDRDetectionTests.swift
//  ShuTaPlaTests
//
//  The HDR vocabulary and its cache. `VideoColorTags` is the pure map from a video's CoreMedia
//  colour tags to the mpv-style strings the HDR path speaks (and the `isHDR` flag derived from the
//  transfer); the format-description read and the libmpv fallback are thin I/O around this table, so
//  the table is asserted here without opening a file. `HDRCache` is the one sink every decode
//  producer routes its finding through — it writes the columns and persists them so an
//  `includePendingChanges = false` object fetch can't refault the write away.
//

import Testing
import Foundation
import CoreMedia
import SwiftData
@testable import ShuTaPla

@Suite struct VideoColorTagsTests {

    /// Each recognised CoreMedia transfer function maps to its mpv string; an SDR or absent
    /// tag maps to `bt.709`/`nil`, never a false HDR value.
    @Test(arguments: [
        (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String, "pq"),
        (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String, "hlg"),
        (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, "bt.709"),
    ] as [(String?, String)])
    func gammaMapsCoreMediaTransferFunctions(input: String?, expected: String) {
        #expect(VideoColorTags.mpvGamma(input) == expected)
    }

    /// Each recognised CoreMedia primaries value maps to its mpv string.
    @Test(arguments: [
        (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String, "bt.2020"),
        (kCMFormatDescriptionColorPrimaries_P3_D65 as String, "display-p3"),
        (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, "bt.709"),
    ] as [(String?, String)])
    func primariesMapCoreMediaColorPrimaries(input: String?, expected: String) {
        #expect(VideoColorTags.mpvPrimaries(input) == expected)
    }

    /// A missing or unrecognised tag maps to `nil` — an SDR file with no colour tags reads as
    /// SDR rather than being forced onto a wrong value.
    @Test func absentOrUnknownTagsMapToNil() {
        #expect(VideoColorTags.mpvGamma(nil) == nil)
        #expect(VideoColorTags.mpvPrimaries(nil) == nil)
        #expect(VideoColorTags.mpvGamma("Something-Else") == nil)
        #expect(VideoColorTags.mpvPrimaries("Something-Else") == nil)
    }

    /// `isHDR` is true only for the PQ/HLG transfers; SDR, unrecognised, and absent gammas are SDR.
    @Test func isHDRIsExactlyPQorHLG() {
        #expect(VideoColorTags.isHDR(gamma: "pq"))
        #expect(VideoColorTags.isHDR(gamma: "hlg"))
        #expect(!VideoColorTags.isHDR(gamma: "bt.709"))
        #expect(!VideoColorTags.isHDR(gamma: nil))
    }
}

@MainActor
struct HDRCacheTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Records an image's decoded HDR range on the model and persists it, so a store-only object
    /// fetch (which refaults a dirty registered object back to saved values) keeps the badge fact.
    @Test func recordsImageHDRAndPersists() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "I", folderBookmark: Data(), folderPath: "/i", mediaType: .image)
        context.insert(playlist)
        let file = insertFile("a.heic", order: 0, to: playlist, in: context)
        try context.save()                       // a stored, non-dirty row (isHDR nil)

        HDRCache().record(imageIsHDR: true, for: file)
        #expect(file.isHDR == true)

        _ = context.files(in: playlist, atRelativePaths: [file.relativePath])
        #expect(file.isHDR == true)              // survived the object refault → it was saved
    }

    /// A decoded SDR still is a determined `false`, not a left-`nil`: the sink caches it so the
    /// gallery won't treat the file as incomplete and re-decode it forever.
    @Test func recordsDecodedSDRImageAsDeterminedFalse() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "I", folderBookmark: Data(), folderPath: "/i", mediaType: .image)
        context.insert(playlist)
        let file = insertFile("a.heic", order: 0, to: playlist, in: context)
        try context.save()

        HDRCache().record(imageIsHDR: false, for: file)
        #expect(file.isHDR == false)

        _ = context.files(in: playlist, atRelativePaths: [file.relativePath])
        #expect(file.isHDR == false)
    }

    /// A video's PQ tags settle `isHDR` from the gamma and cache the colour strings the layer
    /// pre-configures from, all persisted.
    @Test func recordsVideoHDRTagsAndDerivesFlag() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(playlist)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        try context.save()

        HDRCache().record(gamma: "pq", primaries: "bt.2020", for: file)
        #expect(file.isHDR == true)
        #expect(file.hdrGamma == "pq")
        #expect(file.hdrPrimaries == "bt.2020")

        _ = context.files(in: playlist, atRelativePaths: [file.relativePath])
        #expect(file.isHDR == true)
        #expect(file.hdrGamma == "pq")
        #expect(file.hdrPrimaries == "bt.2020")
    }

    /// A decoded SDR video (no PQ/HLG transfer) settles `isHDR` to a determined `false` — the sink
    /// is only ever called from a decode surface, so a non-HDR gamma is a real reading, not a guess.
    @Test func recordsDecodedSDRVideoAsDeterminedFalse() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(playlist)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        try context.save()

        HDRCache().record(gamma: "bt.1886", primaries: "bt.709", for: file)
        #expect(file.isHDR == false)

        _ = context.files(in: playlist, atRelativePaths: [file.relativePath])
        #expect(file.isHDR == false)
    }

    /// A re-decode that settles the same image range writes nothing: every fresh thumbnail reports
    /// its finding here, and an equal write would re-render each view reading the badge and dirty
    /// the record for a fact that never moved. The changed half is the control — the gate suppresses
    /// only no-op writes.
    @Test func recordingAnUnchangedImageRangeInvalidatesNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "I", folderBookmark: Data(), folderPath: "/i", mediaType: .image)
        context.insert(playlist)
        let file = insertFile("a.heic", order: 0, to: playlist, in: context)
        try context.save()

        let sink = HDRCache()
        sink.record(imageIsHDR: true, for: file)

        #expect(!firesObservation(reading: { _ = file.isHDR },
                                  on: { sink.record(imageIsHDR: true, for: file) }))
        #expect(firesObservation(reading: { _ = file.isHDR },
                                 on: { sink.record(imageIsHDR: false, for: file) }))
        #expect(file.isHDR == false)
    }

    /// The same for the video sink, across all three columns it writes: restating a decode's tags
    /// invalidates nothing, while a genuinely new tag still notifies and is written.
    @Test func recordingUnchangedVideoTagsInvalidatesNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(playlist)
        let file = insertFile("a.mp4", order: 0, to: playlist, in: context)
        try context.save()

        let sink = HDRCache()
        sink.record(gamma: "pq", primaries: "bt.2020", for: file)

        let allColumns = { _ = file.isHDR; _ = file.hdrGamma; _ = file.hdrPrimaries }
        #expect(!firesObservation(reading: allColumns,
                                  on: { sink.record(gamma: "pq", primaries: "bt.2020", for: file) }))
        #expect(firesObservation(reading: allColumns,
                                 on: { sink.record(gamma: "pq", primaries: "display-p3", for: file) }))
        #expect(file.hdrPrimaries == "display-p3")
    }

    /// The thumbnail-result dispatch — the surface `GalleryCell` calls — routes each `ThumbnailHDR`
    /// case to the matching column writer: an `.image` finding settles `isHDR` alone; a `.video`
    /// finding settles the flag from the gamma and caches the colour strings.
    @Test func recordDispatchesThumbnailHDRByType() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let image = Playlist(name: "I", folderBookmark: Data(), folderPath: "/i", mediaType: .image)
        let video = Playlist(name: "V", folderBookmark: Data(), folderPath: "/v", mediaType: .video)
        context.insert(image)
        context.insert(video)
        let stillFile = insertFile("a.heic", order: 0, to: image, in: context)
        let videoFile = insertFile("a.mp4", order: 0, to: video, in: context)
        try context.save()

        let sink = HDRCache()
        sink.record(.image(true), for: stillFile)
        #expect(stillFile.isHDR == true)
        #expect(stillFile.hdrGamma == nil)          // a still carries no colour tags

        sink.record(.video(gamma: "pq", primaries: "bt.2020"), for: videoFile)
        #expect(videoFile.isHDR == true)
        #expect(videoFile.hdrGamma == "pq")
        #expect(videoFile.hdrPrimaries == "bt.2020")
    }
}
