import Testing
import Foundation
import AppKit
@testable import ShuTaPla

/// Exercises the playback engines.
///
/// The mpv-backed engines (`VideoPlaybackEngine`/`AudioPlaybackEngine`) share all
/// their logic in `MPVPlaybackEngine`, so the shared behavior is driven through
/// `AudioPlaybackEngine`: like `MPVClientTests` it uses the `--vo=null` audio
/// configuration and libavfilter virtual sources (`av://lavfi:…`), so nothing
/// opens a window and no media fixture is needed in the sandboxed test host. The
/// video engine adds only its render view over the same base; its frame output is
/// verified once the player views host it (Tasks 11–12).
@MainActor
@Suite struct PlaybackEngineTests {

    // MARK: - Helpers

    /// A libavfilter sine tone of the given length, loadable by mpv with no file.
    private func sine(_ seconds: Int) -> String {
        "av://lavfi:sine=frequency=440:duration=\(seconds)"
    }

    /// Polls `condition` on the main actor until it holds or `timeout` elapses,
    /// yielding between checks so the engine's event task can make progress.
    private func poll(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Writes a tiny opaque PNG to a temp file and returns its URL.
    private func writeTempImage(width: Int = 8, height: Int = 8) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let data = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    /// Writes an empty placeholder file and returns its URL. An empty file fails to load
    /// (END_FILE reason `error`, not a natural EOF), so loading it never triggers an
    /// `advanceToNext` that could run after the test host tears down.
    private func writeTempEmptyFile(ext: String = "mp3") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).\(ext)")
        try Data().write(to: url)
        return url
    }

    /// A `PlaylistFile` standing in as an identity token (not inserted in a context).
    private func makeFile(_ name: String) -> PlaylistFile {
        PlaylistFile(relativePath: name, fileName: name)
    }

    // MARK: - mpv engine (via AudioPlaybackEngine)

    @Test func loadStartsPlaybackAndTimeAdvances() async throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }

        engine.load(nil, resource: sine(5))

        let advanced = await poll(timeout: .seconds(10)) { engine.currentTime > 0 }
        #expect(advanced)
        #expect(engine.isPlaying)
    }

    @Test func advanceToNextLoadsSuccessorAndNotifiesSource() throws {
        // The unattended end-of-file path drives the engine's `advanceToNext` directly.
        // Exercise that synchronously rather than waiting on a real natural EOF (which would
        // race the test host's teardown): the engine anchors on the first file, then advances.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)   // anchor on the first file

        #expect(engine.advanceToNext())
        #expect(source.advancedTo == [second.id])
    }

    @Test func loopToggleReachesClient() async throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(nil, resource: sine(30))

        #expect(!engine.isLooping)
        engine.setLooping(true)
        #expect(engine.isLooping)
        #expect(await poll(timeout: .seconds(5)) { engine.client.isLooping })

        engine.setLooping(false)
        #expect(!engine.isLooping)
        #expect(await poll(timeout: .seconds(5)) { !engine.client.isLooping })
    }

    @Test func loadingANewFileResetsLooping() async throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }

        engine.load(makeFile("a"), resource: sine(30))
        engine.setLooping(true)
        #expect(engine.isLooping)
        #expect(await poll(timeout: .seconds(5)) { engine.client.isLooping })

        // Loading the next file (what explicit advance/previous do) starts it unlooped:
        // looping is a per-file choice, not a sticky engine mode.
        engine.load(makeFile("b"), resource: sine(30))
        #expect(!engine.isLooping)
        #expect(await poll(timeout: .seconds(5)) { !engine.client.isLooping })
    }

    @Test func seekMovesTime() async throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }
        engine.load(nil, resource: sine(30))

        _ = await poll(timeout: .seconds(8)) { engine.duration > 0 }
        engine.seek(to: 10)

        let seeked = await poll(timeout: .seconds(8)) { engine.currentTime >= 9 }
        #expect(seeked)
    }

    @Test func volumeForwardsToClient() async throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }

        engine.volume = 42
        #expect(await poll(timeout: .seconds(5)) { abs(engine.client.volume - 42) < 0.5 })
    }

    @Test func stopClearsState() async throws {
        let engine = try AudioPlaybackEngine()
        defer { engine.shutdown() }

        let file = makeFile("a")
        engine.load(file, resource: sine(30))
        #expect(engine.currentFile === file)

        engine.stop()
        #expect(engine.currentFile == nil)
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0)
    }

    // MARK: - Image engine

    @Test func loadPublishesImageAtIdentityTransform() async throws {
        let url = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = ImagePlaybackEngine()
        engine.transform = ImageTransform(offset: CGSize(width: 10, height: 5), scale: 2)
        engine.load(nil, at: url)

        #expect(engine.transform == .identity)   // reset synchronously on load
        #expect(await poll(timeout: .seconds(5)) { engine.currentImage != nil })
    }

    @Test func fitModeCyclesAndResetsTransform() {
        let engine = ImagePlaybackEngine()
        engine.transform = ImageTransform(offset: CGSize(width: 4, height: 4), scale: 3)

        #expect(engine.fitMode == .fit)
        engine.cycleFitMode()
        #expect(engine.fitMode == .cover)
        #expect(engine.transform == .identity)

        engine.cycleFitMode()
        #expect(engine.fitMode == .original)
        engine.cycleFitMode()
        #expect(engine.fitMode == .fit)
    }

    @Test func advanceNotifiesSourceOfTheLandedFile() throws {
        // The unattended advance paths (end-of-file, slideshow) drive the engine's
        // advanceToNext directly, so it must report the file it lands on — that is the
        // only channel that keeps the persisted current-file pointer in step.
        let url = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("1")
        let second = makeFile("2")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = ImagePlaybackEngine()
        engine.source = source
        engine.load(first, at: url)

        #expect(engine.advanceToNext())
        #expect(source.advancedTo == [second.id])

        #expect(engine.returnToPrevious())
        #expect(source.advancedTo == [second.id, first.id])
    }

    @Test func slideshowAdvancesAfterInterval() async throws {
        let url = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("1")
        let second = makeFile("2")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = ImagePlaybackEngine()
        engine.source = source
        engine.load(first, at: url)
        engine.startSlideshow(interval: 0.1)
        defer { engine.stopSlideshow() }   // always halt the timer, even if an assertion fails

        let advanced = await poll(timeout: .seconds(3)) { source.fileAfterCalls > 0 }
        #expect(advanced)
    }

    @Test func stopSlideshowDisablesIt() {
        let engine = ImagePlaybackEngine()
        engine.startSlideshow(interval: 5)   // long interval: it never fires before we stop it
        #expect(engine.slideshowEnabled)

        engine.stopSlideshow()
        #expect(!engine.slideshowEnabled)
    }
}

/// A `PlaybackSource` that walks a fixed file list with wrap-around and records
/// how often the engine asked for an adjacent file.
@MainActor
final class MockPlaybackSource: PlaybackSource {
    var files: [PlaylistFile]
    var urlByID: [UUID: URL] = [:]
    private(set) var fileAfterCalls = 0
    private(set) var fileBeforeCalls = 0
    private(set) var advancedTo: [UUID] = []

    init(files: [PlaylistFile] = []) { self.files = files }

    func fileAfter(_ current: PlaylistFile?) -> PlaylistFile? {
        fileAfterCalls += 1
        guard let current else { return files.first }
        return files.cyclicSuccessor { $0.id == current.id }
    }

    func fileBefore(_ current: PlaylistFile?) -> PlaylistFile? {
        fileBeforeCalls += 1
        guard let current else { return files.last }
        return files.cyclicPredecessor { $0.id == current.id }
    }

    func url(for file: PlaylistFile) -> URL? { urlByID[file.id] }

    func engineDidAdvance(to file: PlaylistFile) { advancedTo.append(file.id) }
}
