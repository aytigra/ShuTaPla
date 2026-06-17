//
//  AudioStripperTests.swift
//  ShuTaPlaTests
//
//  Audio removal over the real codec-labeled samples in `test_media/videos`.
//  `AudioStripper` remuxes a video through libavformat — copying the video stream's
//  packets into a fresh container and dropping audio — for both an AVFoundation-class
//  container (h264/mp4) and a libmpv-only one (vp9/webm).
//
//  Guards that the stream copy actually produces a playable, audio-free file rather
//  than reporting success without writing output.
//

import Testing
import Foundation
import AVFoundation
@testable import ShuTaPla

@Suite struct AudioStripperTests {

    /// `test_media/videos`, two levels up from this test file (the repo root).
    private static var videosDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "test_media/videos", directoryHint: .isDirectory)
    }

    /// The first sample whose filename starts with `prefix`, sidestepping the
    /// bracketed tag suffixes and `(N)` variants some names carry.
    private static func sample(prefix: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: videosDirectory, includingPropertiesForKeys: nil
        )
        return try #require(
            files.first { $0.lastPathComponent.hasPrefix(prefix) },
            "no sample with prefix \(prefix) in \(videosDirectory.path)"
        )
    }

    private static func tempOutput(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "strip-test-\(UUID().uuidString).\(ext)")
    }

    // The encode finishes and writes a non-empty file for both the AVFoundation-class
    // container (h264/mp4) and the libmpv-only one (vp9/webm).
    @Test(arguments: [("h264", "mp4"), ("vp9", "webm")])
    func stripWritesAudioFreeOutput(_ prefix: String, _ ext: String) async throws {
        let input = try Self.sample(prefix: prefix)
        let output = Self.tempOutput(extension: ext)
        defer { try? FileManager.default.removeItem(at: output) }

        let ok = await AudioStripper.stripAudio(at: input, to: output)
        #expect(ok, "\(prefix): remux reported failure")
        #expect(FileManager.default.fileExists(atPath: output.path), "\(prefix): no output written")
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0, "\(prefix): output is empty")
    }

    // For the h264 sample AVFoundation can read the result back: it must keep a video
    // track and carry no audio track.
    @Test func h264OutputHasVideoButNoAudio() async throws {
        let input = try Self.sample(prefix: "h264")
        let output = Self.tempOutput(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(await AudioStripper.stripAudio(at: input, to: output))

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(!video.isEmpty, "video track was dropped")
        #expect(audio.isEmpty, "audio track survived")
    }
}
