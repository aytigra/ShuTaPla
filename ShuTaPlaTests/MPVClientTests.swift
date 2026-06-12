import Testing
import Foundation
@testable import ShuTaPla

/// Exercises `MPVClient` against a real libmpv instance.
///
/// Tests drive mpv's built-in libavfilter virtual sources (`av://lavfi:…`) rather than a media
/// file on disk: they need no fixture and no subprocess, so they run inside the sandboxed test
/// host. Every client uses the audio configuration (`--vo=null`) so nothing opens a window.
@Suite struct MPVClientTests {

    /// A libavfilter sine tone of the given length, addressable by mpv with no file on disk.
    private func sine(seconds: Int) -> String {
        "av://lavfi:sine=frequency=440:duration=\(seconds)"
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
        let client = try MPVClient(configuration: .audio)
        client.shutdown()
    }

    @Test func loadingFileEmitsDurationAndTimePosition() async throws {
        let client = try MPVClient(configuration: .audio)
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
        let client = try MPVClient(configuration: .audio)
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
        let client = try MPVClient(configuration: .audio)
        defer { client.shutdown() }

        client.loadFile(sine(seconds: 30))
        client.play()

        let seeked = await withEventTimeout(.seconds(12)) {
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

    @Test func volumeRoundTrips() throws {
        let client = try MPVClient(configuration: .audio)
        defer { client.shutdown() }

        // The setter dispatches async and the getter reads synchronously on the same serial
        // queue, so the read observes the write (FIFO ordering on the queue).
        client.volume = 50
        #expect(abs(client.volume - 50) < 0.5)

        client.volume = 80
        #expect(abs(client.volume - 80) < 0.5)
    }

    @Test func endOfFileEmittedAtNaturalEnd() async throws {
        let client = try MPVClient(configuration: .audio)
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
