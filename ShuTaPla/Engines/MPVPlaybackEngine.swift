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
        observeEvents()
    }

    /// Stops event consumption and tears down the client. Safe to call once.
    func shutdown() {
        eventTask?.cancel()
        eventTask = nil
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
        currentTime = 0                // no stale position while pending; `startFile` sets the real one
        videoSize = .zero              // the new file re-reports its size; don't linger on the old one
        isPlaying = false
        cloudLoad.load(file) { [weak self] in
            self?.startFile(resource: resource, startingAt: position)
        } requestDownload: { [weak self] in
            self?.source?.requestDownload($0)
        }
    }

    /// Hands the resource to mpv and starts it — the byte-touching load, run at once for a
    /// `.local` file or deferred by `cloudLoad` until an evicted file arrives.
    private func startFile(resource: String, startingAt position: TimeInterval?) {
        currentTime = position ?? 0    // optimistic; mpv's seek is async and corrects it via `time-pos`
        isPlaying = true               // optimistic; corrected by the next `pause` event
        if isLooping { setLooping(false) }   // looping is per-file; a new file starts unlooped
        client.loadFile(resource, startingAt: position)
        client.play()
    }

    func play() { client.play() }
    func pause() { client.pause() }

    /// Stops playback and clears the engine's current-file/position state.
    func stop() {
        cloudLoad.cancel()
        client.stop()
        isPlaying = false
        currentTime = 0
        currentFile = nil
    }

    /// Seeks to an absolute position in seconds.
    func seek(to seconds: TimeInterval) { client.seek(to: seconds) }

    /// Seeks by a relative offset in seconds (the ±3s hotkey passes ±3 here).
    func seek(by delta: TimeInterval) { client.seek(by: delta) }

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
        case .logMessage(let text):
            print("mpv \(text)")
        case .endFile, .fileLoaded, .shutdown:
            break
        }
    }

    // MARK: - Helpers

    /// The string mpv's `loadfile` expects: a plain filesystem path for file URLs,
    /// the full URL for everything else (network/protocol sources).
    static func mpvResource(for url: URL) -> String {
        url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
    }
}
