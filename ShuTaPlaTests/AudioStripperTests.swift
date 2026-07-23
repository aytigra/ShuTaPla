//
//  AudioStripperTests.swift
//  ShuTaPlaTests
//
//  Audio removal over the committed per-codec fixtures (`MediaFixture`).
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

    private static func tempOutput(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "strip-test-\(UUID().uuidString).\(ext)")
    }

    // The encode finishes and writes a non-empty file for both the AVFoundation-class
    // container (h264/mp4) and the libmpv-only one (vp9/webm).
    @Test(arguments: [MediaFixture.h264, .vp9])
    func stripWritesAudioFreeOutput(_ fixture: MediaFixture) async throws {
        let input = try fixture.url
        let output = Self.tempOutput(extension: input.pathExtension)
        defer { try? FileManager.default.removeItem(at: output) }

        let ok = await AudioStripper.stripAudio(at: input, to: output)
        #expect(ok, "\(fixture): remux reported failure")
        #expect(FileManager.default.fileExists(atPath: output.path), "\(fixture): no output written")
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0, "\(fixture): output is empty")
    }

    // For the h264 sample AVFoundation can read the result back: it must keep a video
    // track and carry no audio track.
    @Test func h264OutputHasVideoButNoAudio() async throws {
        let input = try MediaFixture.h264.url
        let output = Self.tempOutput(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(await AudioStripper.stripAudio(at: input, to: output))

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(!video.isEmpty, "video track was dropped")
        #expect(audio.isEmpty, "audio track survived")
    }

    // A remux that fails after opening the output (a video stream into a WAV container the
    // muxer rejects) must not leave a truncated file behind.
    @Test func failedRemuxLeavesNoOutputFile() async throws {
        let input = try MediaFixture.h264.url
        let output = Self.tempOutput(extension: "wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let ok = await AudioStripper.stripAudio(at: input, to: output)
        #expect(!ok, "wav muxer unexpectedly accepted a video stream")
        #expect(!FileManager.default.fileExists(atPath: output.path), "partial output left behind")
    }
}
