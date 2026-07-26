//
//  ImagePlaybackEngineTests.swift
//  ShuTaPlaTests
//
//  The image half of the decode-time HDR producer set (task 23, step 3). The image engine decodes
//  each file with `kCGImageSourceDecodeToHDR` for display; the decoded `CGImage`'s HDR range is a
//  decode-time fact, so the engine records it to the sink for the file it shows — exactly as the
//  video engine records its live `video-params`. A real decode drives it here: a PQ HEIC settles a
//  determined `true`, an SDR PNG a determined `false` (never left `nil`), so the gallery won't keep
//  treating a displayed image as HDR-incomplete.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import UniformTypeIdentifiers
@testable import ShuTaPla

@Suite @MainActor struct ImagePlaybackEngineTests {

    /// A saved `PlaylistFile` in a held in-memory container — the production shape, where the engine's
    /// `currentFile` always comes from the store, so `existsInStore` reads `true` and the sink's
    /// `trySave()` persists. The container is returned for the caller to hold for the whole body
    /// (trap class 1); the recorded HDR fact is asserted on the same live instance.
    private func makeFile(_ name: String) throws -> (ModelContainer, PlaylistFile) {
        let schema = Schema([Playlist.self, PlaylistFile.self, ShuTaPla.Tag.self, AppStateModel.self, GlobalSettings.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let file = PlaylistFile(relativePath: name, fileName: name)
        container.mainContext.insert(file)
        try container.mainContext.save()
        return (container, file)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` elapses, yielding between
    /// checks so the engine's off-main decode can land.
    private func poll(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Writes a tiny SDR PNG (device RGB, no HDR range) to a temp file.
    private func writeSDRImage() throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        return try write(image, as: UTType.png, ext: "png")
    }

    /// Writes a tiny HDR image (16-bit, PQ colour space) to a temp HEIC — the transfer function
    /// survives the round-trip, so a `DecodeToHDR` decode reads it back as HDR.
    private func writeHDRImage() throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        let ctx = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 16,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        let image = try #require(ctx.makeImage())
        return try write(image, as: UTType.heic, ext: "heic")
    }

    private func write(_ image: CGImage, as type: UTType, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// The engine decodes an HDR image and records a determined `true` for the file it shows.
    @Test func decodingHDRImageRecordsTrue() async throws {
        let url = try writeHDRImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let (container, file) = try makeFile("hdr.heic")
        _ = container
        let engine = ImagePlaybackEngine()
        defer { engine.stop() }

        engine.load(file, at: url)
        #expect(await poll(timeout: .seconds(10)) { engine.currentImage != nil })
        #expect(await poll(timeout: .seconds(5)) { file.isHDR != nil })
        #expect(file.isHDR == true)
    }

    /// A decoded SDR image settles a determined `false`, not left `nil`.
    @Test func decodingSDRImageRecordsFalse() async throws {
        let url = try writeSDRImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let (container, file) = try makeFile("sdr.png")
        _ = container
        let engine = ImagePlaybackEngine()
        defer { engine.stop() }

        engine.load(file, at: url)
        #expect(await poll(timeout: .seconds(10)) { engine.currentImage != nil })
        #expect(await poll(timeout: .seconds(5)) { file.isHDR != nil })
        #expect(file.isHDR == false)
    }
}
