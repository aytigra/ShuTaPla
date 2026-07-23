//
//  MPVPlaybackEngine.swift
//  ShuTaPla
//
//  The shared implementation behind `VideoPlaybackEngine` and
//  `AudioPlaybackEngine`. Both own one `MPVClient` and expose the same playback
//  surface; they differ only in how the client is configured (video renders into
//  an embedded view, audio uses `--vo=null`). That difference is captured at
//  construction, so all the playback logic — loading, time/duration/pause
//  observation, looping, seeking, and end-of-file advance — lives here once.
//
//  The engine is `@MainActor @Observable`: it consumes its client's event stream
//  on the main actor and writes its observable state directly, so SwiftUI (and the
//  `PlaybackCoordinator`) track `currentTime`/`duration`/`isPlaying` with no
//  extra plumbing. `currentFile` is the engine's notion of "now playing"; the
//  `source` decides what comes next.
//

import Foundation
import CoreGraphics

@MainActor
@Observable
class MPVPlaybackEngine: SourceNavigating {

    // MARK: - Observable playback state

    /// Current playback position in seconds (observed `time-pos`).
    private(set) var currentTime: TimeInterval = 0

    /// Duration of the current file in seconds, or 0 until known.
    private(set) var duration: TimeInterval = 0

    /// The decoded video's display size (observed `dwidth` / `dheight`), or `.zero` until known.
    /// The Manager preview reads this for its card's aspect ratio; audio (`vo=null`) leaves it zero.
    private(set) var videoSize: CGSize = .zero

    /// Whether the file is advancing (not paused). Driven by mpv's `pause` so it
    /// reflects the engine's real state rather than the last requested command.
    private(set) var isPlaying: Bool = false

    /// Whether the current file loops forever (`loop-file=inf`). Toggle via
    /// `setLooping(_:)`/`toggleLoop()`.
    private(set) var isLooping: Bool = false

    /// The transport's standing play/pause intent, tracking the last `play()`/`pause()` command
    /// (a fresh `load` resets it to play). A `.local` file loads and applies this at once; a
    /// deferred evicted-file load reads it on arrival so a channel paused/suppressed while the
    /// file downloaded doesn't auto-start when its bytes land.
    private var wantsPlayback = true

    /// The file the engine considers current. `nil` when stopped or idle. Set on
    /// load and used as the anchor for advance/previous.
    private(set) var currentFile: PlaylistFile?

    /// Playback volume, 0–100 (mpv's scale). Writes are forwarded to the client.
    var volume: Double = 100 {
        didSet { client.volume = volume }
    }

    /// Supplies the next/previous file and its URL on advance. Set by the
    /// coordinator when a playlist starts; weak so the coordinator owns the cycle.
    weak var source: PlaybackSource?

    /// The `currentTime` a forward keyframe step was issued from, armed by `seek(by:)` and
    /// consumed by the step's settled `playbackRestart` to detect the end of the file. `nil`
    /// when no forward step is awaiting its landing; every other load/seek/stop disarms it so
    /// an unrelated restart can't masquerade as the step's landing.
    private var forwardStepOrigin: TimeInterval?

    // MARK: - Underlying client

    /// The libmpv wrapper this engine drives. Exposed for the coordinator and
    /// tests; all routine control goes through the engine's own methods.
    let client: MPVClient

    /// Holds an evicted file pending until its bytes arrive, then runs the real load.
    /// Player views read `cloudLoad.pendingFile` to show the downloading placeholder.
    let cloudLoad = CloudLoadGate()

    private var eventTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Creates the engine and begins consuming its client's events. Embedded video attaches
    /// its render surface after construction (see `VideoPlaybackEngine`); audio and tests use
    /// the window-free `vo=null` client as-is.
    init(configuration: MPVClient.Configuration) throws {
        self.client = try MPVClient(configuration: configuration)
        self.volume = configuration.initialVolume
        self.keyframeStepping = configuration.keyframeStepping
        observeEvents()
    }

    /// Stops event consumption and tears down the client. Safe to call once.
    func shutdown() {
        eventTask?.cancel()
        eventTask = nil
        // Drop any pending evicted-file wait so its armed `cloudStatus` observation can't fire
        // a stray load after teardown (`stop()` cancels for the same reason).
        cloudLoad.cancel()
        // Drop the source so an end-of-file event already in flight when shutdown
        // lands finds nothing to advance to and returns without walking the (now
        // possibly torn-down) playlist's models.
        source = nil
        client.shutdown()
    }

    // MARK: - Loading & transport

    /// Loads `file` from `url` and starts playing. Satisfies `SourceNavigating`, so advance /
    /// previous always start a file from the beginning.
    func load(_ file: PlaylistFile?, at url: URL) {
        load(file, resource: Self.mpvResource(for: url))
    }

    /// Loads `file` from `url`, seeking to `position` seconds — file-position persistence
    /// resumes a video/audio file where it left off.
    func load(_ file: PlaylistFile?, at url: URL, startingAt position: TimeInterval?) {
        load(file, resource: Self.mpvResource(for: url), startingAt: position)
    }

    /// Loads an mpv resource string directly (a file path or a protocol URL such as
    /// `av://…`). The URL-taking overload funnels here; tests drive it with libmpv's
    /// virtual sources, which aren't expressible as `URL`s. An evicted file is held pending
    /// by `cloudLoad` at a rest position (no time, not playing) and its bytes only load once
    /// the live feed reports its arrival; a `.local` file loads at once.
    func load(_ file: PlaylistFile?, resource: String, startingAt position: TimeInterval? = nil) {
        currentFile = file
        forwardStepOrigin = nil        // a fresh load's restart is not a step's landing
        currentTime = 0                // no stale position while pending; `startFile` sets the real one
        videoSize = .zero              // the new file re-reports its size; don't linger on the old one
        isPlaying = false
        if isLooping { setLooping(false) }   // per-file: a new file starts unlooped at once, not on arrival
        wantsPlayback = true           // a fresh load intends to play; the coordinator re-halts after if needed
        cloudLoad.load(file) { [weak self] in
            self?.startFile(resource: resource, startingAt: position)
        } requestDownload: { [weak self] in
            self?.source?.requestDownload($0)
        }
        // A load held pending (evicted file) never touches the client, so rest it — otherwise the
        // previous file keeps decoding and playing behind the downloading placeholder until arrival.
        if cloudLoad.pendingFile != nil { client.stop() }
    }

    /// Hands the resource to mpv and starts it — the byte-touching load, run at once for a
    /// `.local` file or deferred by `cloudLoad` until an evicted file arrives.
    private func startFile(resource: String, startingAt position: TimeInterval?) {
        currentTime = position ?? 0    // optimistic; mpv's seek is async and corrects it via `time-pos`
        isPlaying = wantsPlayback      // optimistic; corrected by the next `pause` event
        client.loadFile(resource, startingAt: position)
        // Honor the standing intent: a deferred load whose channel was paused/suppressed while the
        // evicted file downloaded must land paused, not blare the moment its bytes arrive.
        if wantsPlayback { client.play() } else { client.pause() }
    }

    func play() { wantsPlayback = true; client.play() }
    func pause() { wantsPlayback = false; client.pause() }

    /// Stops playback and clears the engine's current-file/position state.
    func stop() {
        cloudLoad.cancel()
        client.stop()
        isPlaying = false
        currentTime = 0
        currentFile = nil
        forwardStepOrigin = nil
    }

    /// Seeks to an absolute position in seconds. The client snaps to the nearest keyframe at or
    /// before it (the scrubber's target lands within a GOP — fast, standard scrubbing).
    func seek(to seconds: TimeInterval) {
        forwardStepOrigin = nil
        client.seek(to: seconds)
    }

    /// Whether the skip hotkey steps by keyframe (video) or seeks by the full signed delta
    /// (audio — no keyframes, where a plain relative seek is always clean). Fixed per channel
    /// by the configuration.
    private let keyframeStepping: Bool

    /// The skip hotkey. With `keyframeStepping` only the delta's sign is used: forward is one
    /// keyframe seek; backward takes two (anchor on the current keyframe, then hop before it)
    /// because mpv rounds relative keyframe seeks toward the direction of travel and can't
    /// undershoot in one move — see ``MPVClient/stepKeyframe(forward:)``. Either way it lands on
    /// the next / previous keyframe: no overshoot, no stall — steps are keyframe-granular
    /// (~one GOP), not a fixed number of seconds. A forward step also arms end-of-file
    /// detection: its settled restart is compared to the position it was issued from (see the
    /// `.playbackRestart` handling). Without `keyframeStepping` the full delta seeks relatively.
    func seek(by delta: TimeInterval) {
        guard keyframeStepping else {
            client.seek(by: delta)
            return
        }
        let forward = delta > 0
        forwardStepOrigin = forward ? currentTime : nil
        client.stepKeyframe(forward: forward)
    }

    // Advance / previous come from `SourceNavigating` (shared with the image engine).

    // MARK: - Looping

    /// Turns looping on/off, mirroring the state to mpv's `loop-file` property.
    func setLooping(_ looping: Bool) {
        isLooping = looping
        client.isLooping = looping
    }

    func toggleLoop() { setLooping(!isLooping) }

    // MARK: - Event consumption (main actor)

    private func observeEvents() {
        eventTask = Task { [weak self] in
            guard let events = self?.client.events else { return }
            for await event in events {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    /// Folds one client event into observable state. Internal so tests can drive the mapping
    /// directly (the real events arrive off the client's queue).
    func handle(_ event: MPVEvent) {
        switch event {
        case .timePosition(let value):
            currentTime = value ?? 0
        case .duration(let value):
            duration = value ?? 0
        case .videoWidth(let value):
            videoSize.width = CGFloat(value ?? 0)
        case .videoHeight(let value):
            videoSize.height = CGFloat(value ?? 0)
        case .pausedChanged(let paused):
            isPlaying = !paused
        case .endFile(.eof):
            // Natural end. With looping on, mpv replays internally and never reaches
            // here. `advanceToNext` loads the successor, or holds the last frame when
            // this file is the whole sequence (its successor is itself).
            advanceToNext()
        case .playbackRestart(let settled):
            // The settled landing of an armed forward keyframe step: if it didn't move
            // ahead, the file has no next keyframe — its end — so advance instead of
            // sticking there. Files that flip `eof-reached` on the step never get here
            // with a stale origin (the advance's load disarms it).
            if let origin = forwardStepOrigin {
                forwardStepOrigin = nil
                if Self.advanceAfterForwardStep(from: origin, to: settled) { advanceToNext() }
            }
        case .logMessage(let text):
            print("mpv \(text)")
        case .endFile, .fileLoaded, .shutdown:
            break
        }
    }

    // MARK: - Helpers

    /// Whether a settled forward keyframe step means the end of the file. A mid-file forward
    /// step always lands strictly ahead of its origin (forward keyframe seeks round up to the
    /// next keyframe), so a settled position that did not move ahead can only mean there was
    /// no next keyframe to land on — advance instead of sticking on the last one.
    nonisolated static func advanceAfterForwardStep(
        from origin: TimeInterval, to settled: TimeInterval
    ) -> Bool {
        settled <= origin
    }

    /// The string mpv's `loadfile` expects: a plain filesystem path for file URLs,
    /// the full URL for everything else (network/protocol sources).
    static func mpvResource(for url: URL) -> String {
        url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
    }
}
