import Testing
import Foundation
import AppKit
import SwiftData
@testable import ShuTaPla

/// Exercises the playback engines.
///
/// The mpv-backed engines (`VideoPlaybackEngine`/`AudioPlaybackEngine`) share all
/// their logic in `MPVPlaybackEngine`, so the shared behavior is driven through the
/// base engine on the silent test configurations (`--vo=null`, `--ao=null` — no
/// window, no sound; `makeEngine`), with libavfilter virtual sources (`av://lavfi:…`)
/// or a generated WAV where a test must really seek. The video engine adds only its
/// render view over the same base; its frame output is verified once the player
/// views host it (Tasks 11–12).
@MainActor
@Suite struct PlaybackEngineTests {

    // MARK: - Helpers

    /// A libavfilter sine tone of the given length, loadable by mpv with no file. Give it a length
    /// that outlasts everything the test then waits for: the client runs with `keep-open=yes`, so
    /// reaching the end pauses mpv, which arrives as `pausedChanged(true)` and clears `isPlaying`.
    /// A tone that can expire mid-test turns a slow host into a failure about playback state.
    private func sine(_ seconds: Int) -> String {
        "av://lavfi:sine=frequency=440:duration=\(seconds)"
    }

    /// The shared MPV engine on a silent configuration — no window, no sound. Keyframe stepping
    /// (the video channel's skip mode) is opted into by the tests that exercise it.
    private func makeEngine(keyframeStepping: Bool = false) throws -> MPVPlaybackEngine {
        try MPVPlaybackEngine(configuration: keyframeStepping ? .silentKeyframeStepping : .silentAudio)
    }

    /// Polls `condition` on the main actor until it holds or the budget of attempts runs out,
    /// sleeping between checks so the engine's event task can make progress.
    ///
    /// For state that only mpv's event stream can deliver, where there is nothing to await. Never
    /// reach for it when the awaited work has a handle — await that instead (the image engine's
    /// `loadTask`).
    ///
    /// The budget is counted in attempts rather than wall clock, and that is the whole point.
    /// Everything this waits for is delivered on the main actor: mpv drains its events on a private
    /// queue but hands each one to the engine's `@MainActor` event task, and this poll's own
    /// resumption is a main-actor job too. A full-suite run admits every test at once, so hundreds
    /// of main-actor bodies queue on the one thread and even a test doing sub-millisecond work
    /// reports twelve seconds. A wall-clock deadline expires against that congestion while the
    /// engine is merely waiting its turn; a budget of turns is throttled by the very queue that
    /// throttles the work it is watching, so it stretches with the machine and runs out only when
    /// the state genuinely never arrives. 300 × 50 ms is 15 seconds on an idle host.
    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
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

    /// A saved `PlaylistFile` in a held in-memory container — the production shape, where a live
    /// decode's `currentFile` comes from the store, so `existsInStore` reads `true` and the HDR
    /// record persists. The container is returned for the caller to hold for the whole body (trap
    /// class 1); the recorded fact is asserted on the same live instance.
    private func makeStoredFile(_ name: String) throws -> (ModelContainer, PlaylistFile) {
        let schema = appTestSchema
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let file = PlaylistFile(relativePath: name, fileName: name)
        container.mainContext.insert(file)
        try container.mainContext.save()
        return (container, file)
    }

    // MARK: - mpv engine (via AudioPlaybackEngine)

    // Loading starts playback and delivers the load-settled state — a known duration and
    // the playing flag — through the engine's `observeEvents` stream. That the clock then
    // really advances is proven once, at the client level
    // (`MPVClientTests/loadingFileEmitsDurationAndTimePosition`); waiting on real-time
    // progress here would only re-test mpv under a starved main actor.
    @Test func loadDeliversStateThroughEventStream() async throws {
        let engine = try makeEngine()
        defer { engine.shutdown() }

        engine.load(nil, resource: sine(60))

        let settled = await poll { engine.duration > 0 }
        #expect(settled)
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

        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)   // anchor on the first file

        #expect(engine.advanceToNext())
        #expect(source.advancedTo == [second.id])
    }

    @Test func singleElementSequenceHoldsInsteadOfReloading() throws {
        // A one-element sequence's successor (and predecessor) is the file itself. The
        // unattended advance paths (natural EOF, slideshow tick) must hold it in place
        // rather than re-load/re-decode it, so neither steps and the source is never
        // re-notified of the same file.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let only = makeFile("only")
        let source = MockPlaybackSource(files: [only])
        source.urlByID[only.id] = url

        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.source = source
        engine.load(only, at: url)

        #expect(!engine.advanceToNext())
        #expect(!engine.returnToPrevious())
        #expect(source.advancedTo.isEmpty)
        #expect(engine.currentFile === only)
    }

    @Test func loadErrorStallsWithoutAdvancing() throws {
        // Baseline for the missing/evicted-file handling (cloud task, Step 6): an mpv load
        // failure surfaces as `END_FILE` reason `error`, which the engine currently *ignores*
        // — only a natural EOF advances. So an unloadable file leaves the engine anchored on it
        // with nothing playing; it does not skip forward. Any silent-skip on a missing file is
        // therefore new behavior to add, not an existing path to extend.
        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])

        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, resource: sine(5))   // anchor on the first file

        engine.handle(.endFile(.error))          // what a failed/missing-file load reports

        #expect(source.advancedTo.isEmpty)       // did not skip to the next file
        #expect(engine.currentFile === first)    // stayed anchored on the unloadable file
    }

    @Test func advanceAfterShutdownIsANoOp() throws {
        // A natural end-of-file event already in flight when the engine is torn down must
        // not walk the source (whose models may be gone): shutdown drops the source, so a
        // late advance returns false without loading or notifying.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try makeEngine()
        engine.source = source
        engine.load(first, at: url)
        engine.shutdown()

        #expect(!engine.advanceToNext())
        #expect(source.advancedTo.isEmpty)
    }

    @Test(arguments: [
        // landed on the next keyframe, frame rendered: a normal step
        (origin: 50.0, settled: 53.0, frames: (arm: UInt64(7), settle: UInt64(8)), advance: false),
        // did not move: no next keyframe, the end — even though the held frame redrew
        (origin: 50.0, settled: 50.0, frames: (arm: UInt64(7), settle: UInt64(8)), advance: true),
        // floored back onto the last keyframe: the end
        (origin: 50.0, settled: 49.0, frames: (arm: UInt64(7), settle: UInt64(8)), advance: true),
        // frozen video: audio hopped ~ε ahead but no new frame — the end
        (origin: 50.0, settled: 50.24, frames: (arm: UInt64(7), settle: UInt64(7)), advance: true),
        // all-intra: a healthy step is also only ~ε, but its frame rendered — not the end
        (origin: 50.0, settled: 50.24, frames: (arm: UInt64(7), settle: UInt64(8)), advance: false),
        // audio-only file / no render context yet: the count is pinned at 0, so it is "flat" but
        // never meant EOF — the step landed ahead, so hold rather than skip the file
        (origin: 50.0, settled: 50.24, frames: (arm: UInt64(0), settle: UInt64(0)), advance: false),
    ])
    func forwardStepDecision(
        _ scenario: (origin: TimeInterval, settled: TimeInterval,
                     frames: (arm: UInt64, settle: UInt64), advance: Bool)
    ) {
        #expect(MPVPlaybackEngine.advanceAfterForwardStep(
            from: scenario.origin, to: scenario.settled,
            framesAtArm: scenario.frames.arm, framesAtSettle: scenario.frames.settle
        ) == scenario.advance)
    }

    @Test func forwardStepThatCannotAdvanceSwitchesFile() throws {
        // A forward keyframe step in the last GOP has no next keyframe to land on: mpv sticks on
        // the last one, so the step's landing is not ahead of its origin. The engine must
        // advance to the next file instead of leaving playback stuck there.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        engine.handle(.timePosition(50))
        engine.seek(by: 3)                               // forward step issued from 50
        // Settled where it started: no next keyframe. frames moved (the held frame redrew) —
        // the position signal alone must decide the advance.
        engine.handle(.forwardStepSettled(50, frames: 1))

        #expect(source.advancedTo == [second.id])
    }

    @Test func deadForwardStepWithNoSuccessorWrapsToStart() throws {
        // The preview's source never advances (`fileAfter` is nil), and a one-file sequence's
        // successor is itself — either way a dead forward step's advance decision has nowhere
        // to go. The engine must wrap to the start instead of leaving the frozen frame (audio
        // running on) stuck at the end. Observed through `seek(to:)`'s optimistic `currentTime`.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let only = makeFile("only")
        let source = MockPlaybackSource(files: [only])
        source.urlByID[only.id] = url

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(only, at: url)

        engine.handle(.timePosition(58))
        engine.seek(by: 3)                                  // forward step issued from 58
        engine.handle(.forwardStepSettled(58, frames: 1))   // dead: no next keyframe, settled == origin

        #expect(source.advancedTo.isEmpty)                  // nothing to advance to
        #expect(engine.currentTime == 0)                    // wrapped to the start instead
    }

    @Test func forwardStepToEndAdvancesOnceDespiteStaleEof() throws {
        // A forward step that drives every track to EOF makes mpv both settle the step
        // (PLAYBACK_RESTART → .forwardStepSettled) and flip eof-reached (→ .endFile(.eof)):
        // two uncoordinated end signals around the same instant. When the step's settle lands
        // first it advances to the next file; the stale eof that follows is the *same* end and
        // must not advance again — one forward press must skip exactly one file, not two.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let third = makeFile("c")
        let source = MockPlaybackSource(files: [first, second, third])
        for file in [first, second, third] { source.urlByID[file.id] = url }

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        engine.handle(.timePosition(50))
        engine.seek(by: 3)                                  // forward step issued from 50
        engine.handle(.forwardStepSettled(50, frames: 1))   // no next keyframe → advance to B
        engine.handle(.endFile(.eof))                       // stale eof from the same step

        #expect(source.advancedTo == [second.id])           // one advance, not [b, c]
    }

    @Test func genuineEofAfterForwardStepAdvanceStillAdvances() throws {
        // The redundancy marker must not over-suppress. When a forward step reaches only the last
        // keyframe, mpv may never flip eof-reached, so no stale eof arrives to consume the marker —
        // the successor's own `.fileLoaded` clears it. After that, the successor playing to its
        // real end (`.endFile(.eof)`) must advance again, not be swallowed as the step's pair.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let third = makeFile("c")
        let source = MockPlaybackSource(files: [first, second, third])
        for file in [first, second, third] { source.urlByID[file.id] = url }

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        engine.handle(.timePosition(50))
        engine.seek(by: 3)                                  // forward step issued from 50
        engine.handle(.forwardStepSettled(50, frames: 1))   // no next keyframe → advance to B
        engine.handle(.fileLoaded)                          // B is really up; the marker must clear
        engine.handle(.endFile(.eof))                       // B plays to its own genuine end

        #expect(source.advancedTo == [second.id, third.id]) // B's real end still advances to C
    }

    @Test func forwardStepThatLandedAheadDoesNotAdvance() throws {
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        engine.handle(.timePosition(50))
        engine.seek(by: 3)                                  // forward step issued from 50
        engine.handle(.forwardStepSettled(53, frames: 1))   // landed on the next keyframe: a normal step
        // The landing consumed the armed step: a later stray settled event (even one behind the
        // old origin, with a flat frame count) has no armed step and must not advance.
        engine.handle(.forwardStepSettled(50, frames: 1))

        #expect(source.advancedTo.isEmpty)
    }

    @Test func staleStepLandingsDoNotAdvance() throws {
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        // A backward step never arms end detection — a stray settled event behind the press
        // position must not advance, even with a flat frame count.
        engine.handle(.timePosition(50))
        engine.seek(by: -3)
        engine.handle(.forwardStepSettled(47, frames: 0))
        #expect(source.advancedTo.isEmpty)

        // A scrubber seek issued after a forward step takes over (disarms it): the superseded
        // step's late landing — mpv merges the step into the scrub, so it reports the scrub's
        // position — must not be evaluated.
        engine.seek(by: 3)
        engine.seek(to: 10)
        engine.handle(.forwardStepSettled(10, frames: 0))
        #expect(source.advancedTo.isEmpty)

        // A fresh load also supersedes an armed step; a late landing is not the new file's.
        engine.seek(by: 3)
        engine.load(first, at: url)
        engine.handle(.forwardStepSettled(0, frames: 0))
        #expect(source.advancedTo.isEmpty)
    }

    @Test func forwardStepAfterScrubEvaluatesOnlyItsOwnLanding() throws {
        // A step pressed while a scrub is still settling arms from the scrub's optimistic
        // `currentTime` (its target), while the scrub really lands on the keyframe at-or-before
        // it. The client defers the step past the scrub and reports only the step's own landing
        // (`.forwardStepSettled`) — the scrub's floored restart never reaches the engine, so it
        // can't masquerade as the step's landing and falsely read as end-of-file. Mid-file the
        // step's landing is guaranteed ahead of the optimistic origin — no advance; a landing
        // stuck at-or-behind it can only mean the last keyframe — advance.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try makeEngine(keyframeStepping: true)
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        engine.handle(.timePosition(50))
        engine.seek(to: 100)                                   // scrub; optimistic currentTime = 100
        engine.seek(by: 3)                                     // step pressed before the scrub settles
        engine.handle(.forwardStepSettled(101.5, frames: 2))   // the step's own mid-file landing
        #expect(source.advancedTo.isEmpty)                     // a healthy step — no advance

        engine.seek(to: 100)                                   // same shape, near the end
        engine.seek(by: 3)
        engine.handle(.forwardStepSettled(98.5, frames: 3))    // stuck on the last keyframe: the end
        #expect(source.advancedTo == [second.id])
    }

    @Test func loopToggleReachesClient() async throws {
        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.load(nil, resource: sine(30))

        #expect(!engine.isLooping)
        engine.setLooping(true)
        #expect(engine.isLooping)
        #expect(await poll { engine.client.isLooping })

        engine.setLooping(false)
        #expect(!engine.isLooping)
        #expect(await poll { !engine.client.isLooping })
    }

    @Test func loadingANewFileResetsLooping() async throws {
        let engine = try makeEngine()
        defer { engine.shutdown() }

        engine.load(makeFile("a"), resource: sine(30))
        engine.setLooping(true)
        #expect(engine.isLooping)
        #expect(await poll { engine.client.isLooping })

        // Loading the next file (what explicit advance/previous do) starts it unlooped:
        // looping is a per-file choice, not a sticky engine mode.
        engine.load(makeFile("b"), resource: sine(30))
        #expect(!engine.isLooping)
        #expect(await poll { !engine.client.isLooping })
    }

    @Test func loadingAnEvictedFileResetsLoopingImmediately() async throws {
        // The per-file loop reset must not wait for an evicted file's bytes to arrive: while the
        // download is pending, `isLooping` already reflects the new (unlooped) file, not the previous
        // one's loop state left standing behind the downloading placeholder.
        let engine = try makeEngine()
        defer { engine.shutdown() }

        engine.load(makeFile("a"), resource: sine(30))
        engine.setLooping(true)
        #expect(engine.isLooping)

        let evicted = makeFile("b")
        evicted.cloudStatus = .inCloud
        engine.load(evicted, resource: sine(30))
        #expect(engine.cloudLoad.pendingFile === evicted)   // held pending, startFile hasn't run
        #expect(!engine.isLooping)                           // reset up front, not deferred to arrival
    }

    @Test func loopToggledWhileEvictedFileDownloadsSurvivesArrival() async throws {
        // A loop toggled on while an evicted file is still downloading must survive the file's
        // arrival — the deferred byte-load must not undo the user's choice by re-resetting looping.
        let engine = try makeEngine()
        defer { engine.shutdown() }

        let evicted = makeFile("a")
        evicted.cloudStatus = .inCloud
        engine.load(evicted, resource: sine(30))
        #expect(engine.cloudLoad.pendingFile === evicted)   // held pending

        engine.setLooping(true)   // user turns on loop during the download wait
        #expect(engine.isLooping)

        evicted.cloudStatus = .local   // the live feed reports the bytes arrived; the deferred load runs
        #expect(await poll { engine.cloudLoad.pendingFile == nil })

        #expect(engine.isLooping)                                                   // the toggle stands
        #expect(await poll { engine.client.isLooping })
    }

    @Test func seekMovesTime() async throws {
        // A seekable WAV — the lavfi sources used elsewhere are not seekable; see `writeTempWAV`.
        // `seek(to:)` posts the target to `currentTime` optimistically and lets mpv's `time-pos`
        // correct it, so each leg settles as soon as the engine has taken the seek. That mpv really
        // honors it is the client's business, proven in `MPVClientTests`.
        //
        // The load autoplays, so a forward target alone would be reached by plain playback inside
        // the poll budget and the assertion would hold with `seek(to:)` doing nothing at all
        // (measured). Landing *backward* is what only a seek can produce — that leg is what refutes
        // a broken absolute seek, and the range proves it landed on the target rather than merely
        // moved.
        let url = try writeTempWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.load(nil, at: url)

        _ = await poll { engine.duration > 0 }
        engine.seek(to: 25)
        #expect(await poll { engine.currentTime >= 24 })

        engine.seek(to: 3)
        let landedBack = await poll { (2.5...8).contains(engine.currentTime) }
        #expect(landedBack)
    }

    @Test func audioEngineSeeksByTheFullDelta() async throws {
        // Audio has no keyframes, so the audio channel's skip hotkey seeks by the full signed
        // delta (a plain relative seek — always clean on audio), not by keyframe step. The
        // backward direction proves it: playback alone can never move `currentTime` down, and a
        // keyframe "step" back would land ~0.1s away instead of the full 3s.
        let url = try writeTempWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.load(nil, at: url)

        _ = await poll { engine.duration > 0 }
        engine.seek(to: 10)
        #expect(await poll { engine.currentTime >= 9.9 })

        engine.seek(by: -3)
        let landed = await poll { (6.5...7.6).contains(engine.currentTime) }
        #expect(landed)
    }

    @Test func audioEngineDoesNotArmEndDetection() throws {
        // Without keyframe stepping the skip seeks relatively and `eof-reached` covers the end,
        // so a settled event that isn't ahead of the press position must not be read as "no next
        // keyframe" — an audio skip near the start would otherwise skip whole files.
        let url = try writeTempEmptyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("a")
        let second = makeFile("b")
        let source = MockPlaybackSource(files: [first, second])
        source.urlByID[first.id] = url
        source.urlByID[second.id] = url

        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.source = source
        engine.load(first, at: url)

        engine.handle(.timePosition(50))
        engine.seek(by: 3)
        engine.handle(.forwardStepSettled(50, frames: 0))

        #expect(source.advancedTo.isEmpty)
    }

    // MARK: - HDR recording from the live decode

    @Test func videoDecodeRecordsHDRTagsToCache() async throws {
        // A vo=null engine still decodes video and exposes live `video-params`, so the base engine's
        // decoded-params handler records the file's HDR tags to its `HDRCache`. A real BT.2020-PQ
        // fixture must settle `isHDR == true` with its gamma cached — the decode-time fact the badge
        // and the pre-configured PQ layer read, produced only by an actual decode.
        let (container, file) = try makeStoredFile("hdr")
        _ = container
        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.load(file, at: try MediaFixture.hdr.url)

        #expect(await poll { file.isHDR != nil })
        #expect(file.isHDR == true)
        #expect(file.hdrGamma == "pq")
    }

    @Test func videoDecodeRecordsSDRAsDeterminedFalse() async throws {
        // A decoded SDR video (no PQ/HLG transfer) settles a *determined* `false`, not a left-`nil`,
        // so the gallery won't treat the file as HDR-incomplete and re-decode it forever.
        let (container, file) = try makeStoredFile("sdr")
        _ = container
        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.load(file, at: try MediaFixture.h264.url)

        #expect(await poll { file.isHDR != nil })
        #expect(file.isHDR == false)
    }

    @Test func videoDecodeSkipsRecordForFileNotInStore() async throws {
        // The deleted-the-playing-file race (P5): `currentFile` still points at a row whose deletion
        // was saved, and the live-decode handler would write `isHDR`/gamma onto that gone row and trap.
        // `recordColorTags` guards on `existsInStore`, so the tags are dropped instead. A context-less
        // `PlaylistFile` is the safe, non-trapping stand-in — like a deleted-saved row it has no live
        // store row, so the guard must skip it. The record runs in the same handler that sets
        // `videoSize`, so once the decode has reported a width the record decision has been made.
        let file = makeFile("gone")
        let engine = try makeEngine()
        defer { engine.shutdown() }
        engine.load(file, at: try MediaFixture.hdr.url)

        #expect(await poll { engine.videoSize.width > 0 })
        #expect(file.isHDR == nil)
    }

    @Test func volumeForwardsToClient() async throws {
        let engine = try makeEngine()
        defer { engine.shutdown() }

        engine.volume = 42
        #expect(await poll { abs(engine.client.volume - 42) < 0.5 })
    }

    @Test func switchingToEvictedFileStopsThePreviousFile() async throws {
        // A manual switch (Next/Prev/jump) from a playing local file to an evicted (not-yet-local)
        // one holds the new file pending behind a downloading placeholder. The engine must rest mpv
        // while it waits — otherwise the previous file keeps decoding and *audibly playing* behind
        // the placeholder for the whole download. Proven through the live client: once rested,
        // time-pos stops advancing, so `currentTime` no longer climbs.
        let engine = try makeEngine()
        defer { engine.shutdown() }

        engine.load(makeFile("a"), resource: sine(30))
        #expect(await poll { engine.currentTime > 0.5 })   // A is really playing

        let evicted = makeFile("b")
        evicted.cloudStatus = .inCloud
        engine.load(evicted, resource: sine(30))
        #expect(engine.cloudLoad.pendingFile === evicted)   // the switch is genuinely held pending

        // Let any in-flight time-pos event land and the stop take effect, then confirm playback is
        // at rest. If A kept playing, its time-pos events would have climbed `currentTime` past 0.5.
        try? await Task.sleep(for: .seconds(1))
        #expect(engine.currentTime < 0.5)
    }

    @Test func evictedFileArrivingWhilePausedStaysPaused() async throws {
        // A channel paused (or suppressed) while its current file is still evicted holds the file
        // pending with mpv rested. When the bytes arrive, the deferred load must honor the standing
        // pause — not auto-start playback. Otherwise relaunching a Paused playlist (or pausing while
        // an evicted file downloads) starts blaring the moment iCloud delivers the file.
        let engine = try makeEngine()
        defer { engine.shutdown() }

        let evicted = makeFile("a")
        evicted.cloudStatus = .inCloud
        engine.load(evicted, resource: sine(30))
        #expect(engine.cloudLoad.pendingFile === evicted)   // held pending, nothing playing yet

        engine.pause()   // the coordinator's suspend() path: the channel should stay halted

        evicted.cloudStatus = .local   // the live feed reports the bytes arrived
        #expect(await poll { engine.cloudLoad.pendingFile == nil })   // load ran

        // The file is loaded but must be at rest. Give any time-pos event a chance to land.
        try? await Task.sleep(for: .seconds(1))
        #expect(!engine.isPlaying)
        #expect(engine.currentTime < 0.5)
    }

    @Test func shutdownWhilePendingCancelsTheGate() throws {
        // An engine torn down while awaiting an evicted file must cancel its cloud-load gate, exactly
        // as stop() does. Otherwise the armed cloudStatus observation outlives teardown and its later
        // react() dereferences the pending PlaylistFile after its context is gone (trap class 2), or
        // runs a stray deferred load on the already-shut-down client at app quit.
        let engine = try makeEngine()

        let evicted = makeFile("a")
        evicted.cloudStatus = .inCloud
        engine.load(evicted, resource: sine(30))
        #expect(engine.cloudLoad.pendingFile === evicted)   // held pending, gate armed

        engine.shutdown()
        #expect(engine.cloudLoad.pendingFile == nil)         // shutdown cancelled the wait
    }

    @Test func stopClearsState() async throws {
        let engine = try makeEngine()
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

        await engine.loadTask?.value
        #expect(engine.currentImage != nil)
    }

    @Test func changingFitModeResetsTransform() {
        let engine = ImagePlaybackEngine()
        let zoomed = ImageTransform(offset: CGSize(width: 4, height: 4), scale: 3)

        engine.transform = zoomed
        engine.fitMode = .cover                 // a real change clears pan/zoom
        #expect(engine.transform == .identity)

        engine.transform = zoomed
        engine.fitMode = .cover                 // setting the same mode leaves it alone
        #expect(engine.transform == zoomed)
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

    // The timer loop's whole body is one `slideshowTick()` per beat, so the tick is
    // tested directly — no real timer, no wall-clock wait. (That `Task.sleep` loops is
    // platform behavior, not ours to test.)
    @Test func slideshowTickAdvancesWhileEnabled() throws {
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
        engine.startSlideshow(interval: 60)   // long interval: the real timer never fires in-test
        defer { engine.stopSlideshow() }

        engine.slideshowTick()
        #expect(source.advancedTo == [second.id])
    }

    @Test func slideshowTickAfterStopDoesNothing() throws {
        let url = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeFile("1")
        let source = MockPlaybackSource(files: [first, makeFile("2")])
        source.urlByID[first.id] = url

        let engine = ImagePlaybackEngine()
        engine.source = source
        engine.load(first, at: url)
        engine.startSlideshow(interval: 60)
        engine.stopSlideshow()

        engine.slideshowTick()
        #expect(source.advancedTo.isEmpty)
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
    private(set) var downloadRequests: [UUID] = []

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

    func requestDownload(_ file: PlaylistFile) { downloadRequests.append(file.id) }
}
