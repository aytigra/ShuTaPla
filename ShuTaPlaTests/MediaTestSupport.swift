import Foundation
import Testing
@testable import ShuTaPla

/// The committed per-codec media fixtures in `ShuTaPlaTests/Fixtures/`, bundled into the test
/// bundle as resources. Each is tiny — 64×64, ~1s, a few KB — with a silent audio track, so a
/// decode never strains a timeout and the audio-stripping tests have a track to remove.
/// h264/h265/mpeg are AVFoundation-decodable; vp8/vp9 (webm) exercise the libmpv-only path.
/// `hdr` is a 10-bit VP9 tagged BT.2020 PQ (`video-params/gamma == "pq"`) — the libmpv HDR path.
enum MediaFixture: String, CaseIterable {
    case h264 = "h264.mp4"
    case h265 = "h265.mp4"
    case mpeg = "mpeg.mpeg"
    case vp8 = "vp8.webm"
    case vp9 = "vp9.webm"
    case hdr = "hdr.webm"

    /// The fixture's URL inside the test bundle.
    var url: URL {
        get throws {
            let name = URL(filePath: rawValue)
            return try #require(
                Bundle(for: MediaFixtureToken.self).url(
                    forResource: name.deletingPathExtension().lastPathComponent,
                    withExtension: name.pathExtension
                ),
                "fixture \(rawValue) missing from the test bundle"
            )
        }
    }
}

/// Anchors `Bundle(for:)` to the test bundle (an enum can't be a bundle anchor).
private final class MediaFixtureToken {}

/// A raw H.264 elementary stream (no container) that libmpv loads — reporting dimensions — but can
/// never assign a duration: the "file loads yet never reports a duration" case. Kept out of
/// `MediaFixture` so the all-cases duration/HDR guards don't run against a duration-less file.
func durationlessFixtureURL() throws -> URL {
    try #require(
        Bundle(for: MediaFixtureToken.self).url(forResource: "noduration", withExtension: "h264"),
        "fixture noduration.h264 missing from the test bundle")
}

extension MPVClient.Configuration {
    /// The audio channel's configuration, muted for the test host: `ao=null` opens no audio
    /// device, so a test run makes no sound (and touches no audio hardware in the sandbox).
    static let silentAudio = MPVClient.Configuration(
        videoOutput: .null, audioOutput: .null,
        hardwareDecoding: false, initialVolume: 100, keyframeStepping: false)

    /// Silent like ``silentAudio``, but with the video channel's keyframe stepping — drives the
    /// keyframe-step / end-of-file detection logic without the GL surface a real video engine
    /// needs (forbidden in the test host).
    static let silentKeyframeStepping = MPVClient.Configuration(
        videoOutput: .null, audioOutput: .null,
        hardwareDecoding: false, initialVolume: 100, keyframeStepping: true)
}

/// Writes a silent PCM WAV of the given length to a temp file and returns its URL — the fixture
/// for anything that must really *seek*. The lavfi virtual sources (`av://lavfi:…`) are not
/// seekable: a `seek` on them errors and settles nothing, so a test that watches `time-pos` after
/// seeking one can only "pass" by playing to the target in real time. A WAV seeks to any sample.
/// Callers remove the file when done.
func writeTempWAV(seconds: Int) throws -> URL {
    let sampleRate = 8000
    let dataSize = sampleRate * seconds            // 8-bit mono: one byte per sample
    var bytes = Data("RIFF".utf8)
    func appendUInt32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { bytes.append(contentsOf: $0) } }
    func appendUInt16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { bytes.append(contentsOf: $0) } }
    appendUInt32(36 + dataSize)
    bytes.append(contentsOf: Data("WAVEfmt ".utf8))
    appendUInt32(16)                               // fmt chunk size
    appendUInt16(1)                                // PCM
    appendUInt16(1)                                // mono
    appendUInt32(sampleRate)
    appendUInt32(sampleRate)                       // byte rate (1 byte per frame)
    appendUInt16(1)                                // block align
    appendUInt16(8)                                // bits per sample
    bytes.append(contentsOf: Data("data".utf8))
    appendUInt32(dataSize)
    bytes.append(Data(repeating: 0x80, count: dataSize))   // 8-bit silence

    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).wav")
    try bytes.write(to: url)
    return url
}
