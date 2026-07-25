import Testing
import Foundation
import Synchronization
@testable import ShuTaPla

/// Exercises `MPVClient` against a real libmpv instance.
///
/// Tests drive mpv's built-in libavfilter virtual sources (`av://lavfi:…`) — no fixture, no
/// subprocess — except where a test must really *seek* (lavfi sources aren't seekable), which
/// uses a generated WAV (`writeTempWAV`). Every client uses the silent audio configuration
/// (`--vo=null`, `--ao=null`) so nothing opens a window or makes a sound.
@Suite struct MPVClientTests {

    /// A libavfilter sine tone of the given length, addressable by mpv with no file on disk.
    private func sine(seconds: Int) -> String {
        "av://lavfi:sine=frequency=440:duration=\(seconds)"
    }

    /// A libavfilter test-pattern video of the given length, decoded with `vo=null` so it needs no
    /// window. Its decoded `video-params/*` are what the HDR getters read.
    private func testVideo(seconds: Int) -> String {
        "av://lavfi:testsrc=size=320x240:rate=30:duration=\(seconds)"
    }


    /// Runs `body` (which consumes `client.events`) but gives up after `timeout`, returning `nil`
    /// on expiry. Keeps a single consumer on the stream per call.
    private func withEventTimeout<T: Sendable>(
        _ timeout: Duration = .seconds(10),
        _ body: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func createsAndDestroysHandleWithoutCrashing() throws {
        let client = try MPVClient(configuration: .silentAudio)
        client.shutdown()
    }

    @Test func loadingFileEmitsDurationAndTimePosition() async throws {
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(sine(seconds: 5))
        client.play()

        let progressed = await withEventTimeout {
            var sawDuration = false
            var sawTimePosition = false
            for await event in client.events {
                if case .duration(let value?) = event, value > 0 { sawDuration = true }
                if case .timePosition(let value?) = event, value > 0 { sawTimePosition = true }
                if sawDuration && sawTimePosition { return true }
            }
            return nil
        }

        #expect(progressed == true)
    }

    @Test func pauseCommandEmitsPausedChanged() async throws {
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(sine(seconds: 30))
        client.play()

        let paused = await withEventTimeout {
            var requestedPause = false
            for await event in client.events {
                if !requestedPause {
                    client.pause()
                    requestedPause = true
                }
                if case .pausedChanged(true) = event { return true }
            }
            return nil
        }

        #expect(paused == true)
    }

    @Test func seekMovesTimePosition() async throws {
        // A seekable WAV, and a timeout shorter than the seek target: reaching 9s by just
        // playing in real time can't pass this — only the seek can.
        let url = try writeTempWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(url.path(percentEncoded: false))
        client.play()

        let seeked = await withEventTimeout(.seconds(8)) {
            var didSeek = false
            for await event in client.events {
                if case .fileLoaded = event, !didSeek {
                    client.seek(to: 10)
                    didSeek = true
                }
                if didSeek, case .timePosition(let value?) = event, value >= 9 {
                    return true
                }
            }
            return nil
        }

        #expect(seeked == true)
    }

    @Test func absoluteSeekLandsAtExactTarget() async throws {
        // The scrubber must land where the user pointed (mpv exact/hr-seek), not on a keyframe
        // near it. Audio can't discriminate the seek flag (PCM has no keyframes — any flag lands
        // at packet granularity), so this uses the h264 fixture: 1 s, 10 fps, a single keyframe
        // at 0.0. A keyframe-flagged seek to 0.55 floors all the way back to 0.0; an exact seek
        // decodes forward to it. Pausing at fileLoaded freezes playback, so once the seek
        // settles nothing fires anymore — the last observed `time-pos` is the landing itself.
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(try MediaFixture.h264.url.path(percentEncoded: false))
        client.play()

        let landed = Mutex<TimeInterval?>(nil)
        _ = await withEventTimeout(.seconds(3)) { () -> Bool? in
            var didSeek = false
            for await event in client.events {
                if case .fileLoaded = event, !didSeek {
                    client.pause()
                    client.seek(to: 0.55)
                    didSeek = true
                }
                if didSeek, case .timePosition(let value?) = event {
                    landed.withLock { $0 = value }
                }
            }
            return nil
        }

        let position = try #require(landed.withLock { $0 }, "no position observed after the seek")
        #expect(position > 0.4 && position < 0.7, "landed at \(position)")
    }

    @Test func scrubberSeekEmitsNoForwardStepSettled() async throws {
        // `.forwardStepSettled` carries only a forward keyframe step's own landing. A plain
        // scrub's restart must not surface on it — the engine reads the event as an armed step's
        // landing, and a scrub's position masquerading as one falsely reads as end-of-file.
        // Playing ~0.5s past the scrub target leaves the scrub's restart plenty of time to have
        // drained before the check concludes.
        let url = try writeTempWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(url.path(percentEncoded: false))
        client.play()

        let clean = await withEventTimeout(.seconds(8)) { () -> Bool? in
            var didSeek = false
            for await event in client.events {
                if case .fileLoaded = event, !didSeek {
                    client.seek(to: 10)
                    didSeek = true
                }
                if case .forwardStepSettled = event { return false }
                if didSeek, case .timePosition(let value?) = event, value >= 10.5 {
                    return true
                }
            }
            return nil
        }

        #expect(clean == true)
    }

    @Test func forwardStepDuringScrubSettlesAtItsOwnLanding() async throws {
        // Real-mpv proof of the step-landing channel: a forward step pressed while the scrub is
        // still settling emits exactly one `.forwardStepSettled`, at the step's own landing —
        // strictly past the scrub target, since the step adds its epsilon and the WAV's seek
        // granularity (~50 ms chunks) is finer than the epsilon. A scrub's exact seek lands at
        // its target, never past it, so a settled position above it proves the event was not
        // the scrub's restart misattributed to the step.
        let url = try writeTempWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(url.path(percentEncoded: false))
        client.play()

        let settled = await withEventTimeout(.seconds(8)) { () -> TimeInterval? in
            var didSeek = false
            for await event in client.events {
                if case .fileLoaded = event, !didSeek {
                    client.seek(to: 10)
                    client.stepKeyframe(forward: true)   // pressed while the scrub is in flight
                    didSeek = true
                }
                if case .forwardStepSettled(let position, _) = event {
                    return position
                }
            }
            return nil
        }

        let position = try #require(settled)
        #expect(position > 10.0 && position < 11, "settled at \(position)")
    }

    @Test func armedBackStepDoesNotYankTheNextLoadedFile() async throws {
        // F3: a backward keyframe step whose anchor seek produces no restart (pressed with no
        // file loaded) leaves `pendingBackStep` armed. The next file's load fires
        // PLAYBACK_RESTART, which must NOT complete that stale step — otherwise the fresh file is
        // yanked back to its previous keyframe. The h264 fixture has a single keyframe at 0.0, so
        // a stray keyframe hop floors a 0.55 s start all the way to 0.0; an untouched load, paused
        // at fileLoaded so nothing drifts, stays at ~0.55.
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        // Arm the back step first: FIFO on the serial queue runs this before the load below, and
        // with nothing loaded the anchor seek errors — no restart, so the flag stays set.
        client.stepKeyframe(forward: false)
        client.loadFile(try MediaFixture.h264.url.path(percentEncoded: false), startingAt: 0.55)
        client.play()

        let landed = Mutex<TimeInterval?>(nil)
        _ = await withEventTimeout(.seconds(3)) { () -> Bool? in
            var didPause = false
            for await event in client.events {
                if case .fileLoaded = event, !didPause {
                    client.pause()
                    didPause = true
                }
                if case .timePosition(let value?) = event {
                    landed.withLock { $0 = value }
                }
            }
            return nil
        }

        let position = try #require(landed.withLock { $0 }, "no position observed after the load")
        #expect(position > 0.4, "the armed back step yanked the fresh load to \(position)")
    }

    @Test func volumeRoundTrips() throws {
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        // The setter dispatches async and the getter reads synchronously on the same serial
        // queue, so the read observes the write (FIFO ordering on the queue).
        client.volume = 50
        #expect(abs(client.volume - 50) < 0.5)

        client.volume = 80
        #expect(abs(client.volume - 80) < 0.5)
    }

    @Test func propertyReadAfterShutdownDoesNotTouchDestroyedHandle() throws {
        let client = try MPVClient(configuration: .silentAudio)
        client.volume = 50
        client.shutdown()

        // The getter's `queue.sync` runs after shutdown's `queue.async` destroy on the
        // same serial queue; the `isTerminated` guard returns a default instead of
        // reading the freed handle.
        #expect(client.volume == 0)
        #expect(client.isLooping == false)
    }

    @Test func commandAfterShutdownDoesNotTouchDestroyedHandle() throws {
        let client = try MPVClient(configuration: .silentAudio)
        client.loadFile(sine(seconds: 5))
        client.shutdown()

        // Every command/setter dispatches onto the same serial queue *after* shutdown's
        // destroy block. The `isTerminated` guard makes each a no-op instead of calling
        // `mpv_command`/`mpv_set_property` on the freed handle (a use-after-free).
        client.loadFile(sine(seconds: 5))
        client.play()
        client.pause()
        client.stop()
        client.seek(to: 3)
        client.isLooping = true
        client.volume = 70

        // The synchronous read drains the queue (FIFO): had any write above touched the
        // destroyed handle it would have crashed before this returns.
        #expect(client.volume == 0)
    }

    @Test func targetStringPropertyRoundTrips() throws {
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        // The setter dispatches async and the getter reads synchronously on the same serial
        // queue, so the read observes the write (FIFO ordering) — no file needed, `target-*`
        // are output options settable at any time.
        client.setStringProperty("target-trc", "pq")
        #expect(client.stringProperty("target-trc") == "pq")

        client.setStringProperty("target-prim", "bt.2020")
        #expect(client.stringProperty("target-prim") == "bt.2020")
    }

    @Test func stringPropertyReadsDecodedVideoParams() async throws {
        let client = try MPVClient(configuration: .silentAudio)   // vo=null: decodes video, opens no window
        defer { client.shutdown() }

        client.loadFile(testVideo(seconds: 5))
        client.play()

        // `video-params/*` only populate once a frame is decoded; `dwidth` arriving is that signal.
        let primaries = await withEventTimeout { () -> String? in
            for await event in client.events {
                if case .videoWidth(let value?) = event, value > 0 {
                    return client.stringProperty("video-params/primaries")
                }
            }
            return nil
        }

        // A real decoded value (e.g. "bt.709") — the getter reaches live mpv state, not a default.
        #expect(primaries?.isEmpty == false)
    }

    @Test func stringPropertyAfterShutdownDoesNotTouchDestroyedHandle() throws {
        let client = try MPVClient(configuration: .silentAudio)
        client.setStringProperty("target-trc", "pq")
        client.shutdown()

        // The getter's `queue.sync` runs after shutdown's destroy on the same serial queue; the
        // `isTerminated` guard returns nil instead of reading the freed handle. The setter that
        // follows is a no-op for the same reason (it would crash before the read returns otherwise).
        #expect(client.stringProperty("target-trc") == nil)
        client.setStringProperty("target-prim", "bt.2020")
        #expect(client.stringProperty("target-prim") == nil)
    }

    @Test func endOfFileEmittedAtNaturalEnd() async throws {
        let client = try MPVClient(configuration: .silentAudio)
        defer { client.shutdown() }

        client.loadFile(sine(seconds: 1))
        client.play()

        let reachedEnd = await withEventTimeout(.seconds(12)) {
            for await event in client.events {
                if case .endFile(let reason) = event, reason == .eof {
                    return true
                }
            }
            return nil
        }

        #expect(reachedEnd == true)
    }
}
