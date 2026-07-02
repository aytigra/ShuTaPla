import Foundation
import Cmpv

/// A thin Swift wrapper around a single libmpv `mpv_handle`.
///
/// ## Threading & `Sendable`
/// mpv's C API is **not** thread-safe: every call against a given `mpv_handle` must be
/// serialized. This type funnels all access to `handle` through one private serial
/// `DispatchQueue`. Fire-and-forget commands (`loadFile`, `play`, `seek`, …) are dispatched
/// `async`; the small number of property *reads* (`volume`, `isLooping`) use `sync` because
/// they are cheap reads of mpv state. No `handle` access happens off `queue`.
///
/// Because that invariant is upheld manually rather than by the compiler, the type is
/// `@unchecked Sendable`. The only stored state mutated after `init` lives behind `queue`
/// or is itself `Sendable` (`AsyncStream.Continuation`).
///
/// ## Events
/// `mpv_set_wakeup_callback` fires on an arbitrary mpv thread; it does nothing but schedule a
/// drain on `queue`, which pumps `mpv_wait_event` and forwards each translated `MPVEvent`
/// into `events`. That stream has exactly one consumer — the owning playback engine.
nonisolated final class MPVClient: @unchecked Sendable {

    /// How the instance is configured at creation. Video and audio differ only by output.
    struct Configuration: Sendable {
        enum VideoOutput: Sendable {
            /// Render video through the libmpv render API (`--vo=libmpv`) into a render
            /// context the app drives — see ``createRenderContext(updateCallback:)``.
            case embedded
            /// No video output (`--vo=null`) — used by the audio instance and by tests.
            case null
        }

        var videoOutput: VideoOutput
        var hardwareDecoding: Bool
        var initialVolume: Double

        static let video = Configuration(videoOutput: .embedded, hardwareDecoding: true, initialVolume: 100)
        static let audio = Configuration(videoOutput: .null, hardwareDecoding: false, initialVolume: 100)
    }

    /// `nonisolated(unsafe)`: the handle is non-`Sendable`, but every access is serialized
    /// through `queue`, which is the safety invariant this type upholds. The annotation lets it
    /// be captured by the `@Sendable` `queue.async`/`sync` closures that enforce that serialization.
    private nonisolated(unsafe) let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.aytigra.ShuTaPla.mpv")
    private let continuation: AsyncStream<MPVEvent>.Continuation

    /// Serializes use of `renderContext` across the threads that touch it: the
    /// `CAOpenGLLayer` draw thread (`render`/`reportSwap`) and whichever thread frees
    /// it (`freeRenderContext`, on shutdown). It makes a free wait for an in-progress
    /// render to finish and makes a render starting after a free see a `nil` context,
    /// so the draw thread can never render into a freed context.
    private let renderLock = NSLock()

    /// The libmpv render context for embedded video, or `nil` until the GL view creates it
    /// (and for the audio/`vo=null` instances, which never do).
    ///
    /// The render API is intentionally decoupled from the `mpv_handle`'s serial-queue
    /// invariant: `mpv_render_context_create/render/report_swap/free` are called directly on
    /// the GL thread (the `CAOpenGLLayer`'s draw thread) while the core keeps running on its
    /// own threads — this is exactly the usage libmpv's render API is designed for.
    private nonisolated(unsafe) var renderContext: OpaquePointer?

    /// Invoked by libmpv (on an arbitrary thread) when a new frame is ready to render. Set
    /// when the render context is created; reads it to ask the GL layer for a redraw.
    private nonisolated(unsafe) var renderUpdate: (() -> Void)?

    /// Set once, on `queue`, when the handle is being destroyed. A wakeup can schedule a drain
    /// that lands on `queue` after `shutdown` has destroyed the handle; gating both the drain
    /// and `shutdown` itself on this flag (all on the serial queue) prevents that use-after-free
    /// and makes `shutdown` idempotent.
    private nonisolated(unsafe) var isTerminated = false

    /// The single event stream for this instance. Consume it once from the owning engine.
    let events: AsyncStream<MPVEvent>

    // MARK: - Lifecycle

    /// Creates and initializes an mpv instance.
    ///
    /// For embedded video the render surface is attached after construction:
    /// `mpv_initialize` brings the core up with `--vo=libmpv`, then the GL view calls
    /// ``createRenderContext(updateCallback:)`` once its OpenGL context exists. mpv never
    /// creates a window of its own.
    ///
    /// - Parameter configuration: output/decoding/volume options applied before `mpv_initialize`.
    /// - Throws: `MPVError` if the handle cannot be created or initialized.
    init(configuration: Configuration) throws {
        guard let handle = mpv_create() else { throw MPVError.createFailed }
        self.handle = handle

        var continuation: AsyncStream<MPVEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation

        // --- options that must be set before mpv_initialize ---
        switch configuration.videoOutput {
        case .embedded:
            // The render API draws into the app's own GL surface; mpv owns no window.
            setOption("vo", "libmpv")
            setOption("hwdec", configuration.hardwareDecoding ? "auto-safe" : "no")
            setOption("target-colorspace-hint", "yes")   // adapt output to the EDR layer
        case .null:
            setOption("vo", "null")
            setOption("audio-display", "no")
        }

        setOption("idle", "yes")               // stay alive between files
        setOption("force-window", "no")
        setOption("keep-open", "yes")          // emit EOF rather than auto-advancing
        setOption("volume", String(configuration.initialVolume))
        setOption("terminal", "no")

        guard mpv_initialize(handle) >= 0 else {
            mpv_destroy(handle)
            throw MPVError.initializeFailed
        }

        // Surface mpv's own diagnostics (VO/window/embedding decisions, decode errors)
        // on the event stream so they reach the console — otherwise terminal=no hides them.
        mpv_request_log_messages(handle, "v")

        // Observe the properties the engines mirror as UI state.
        mpv_observe_property(handle, PropertyID.timePos, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, PropertyID.duration, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, PropertyID.pause, "pause", MPV_FORMAT_FLAG)
        // With keep-open=yes mpv holds the last frame and signals the natural end by flipping
        // eof-reached rather than emitting END_FILE, so this is the engine's "advance" trigger.
        mpv_observe_property(handle, PropertyID.eofReached, "eof-reached", MPV_FORMAT_FLAG)
        // The decoded display size, for the Manager preview card's aspect ratio.
        mpv_observe_property(handle, PropertyID.dwidth, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, PropertyID.dheight, "dheight", MPV_FORMAT_INT64)

        // Route mpv's wakeups onto our serial drain. The callback fires on an mpv-internal
        // thread; it must be a capture-free literal closure to form a C function pointer, so it
        // recovers `self` from the registered `ctx` and only schedules a drain. `ctx` holds a
        // retain (released in `shutdown`) so a wakeup already in flight on the mpv thread can
        // never resolve a freed instance — the worst case is a leak if `shutdown` is skipped.
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVClient>.fromOpaque(ctx).takeUnretainedValue().scheduleDrain()
        }, Unmanaged.passRetained(self).toOpaque())
    }

    /// Tears the instance down: frees the render context (must happen before the handle is
    /// destroyed), stops wakeups, finishes the event stream, and destroys the handle on
    /// `queue`. Idempotent. Commands and setters enqueued after this run as no-ops: each
    /// guards on `isTerminated` (set here, on the same serial queue) so none touches the
    /// freed handle.
    func shutdown() {
        freeRenderContext()
        queue.async {
            guard !self.isTerminated else { return }
            self.isTerminated = true
            mpv_set_wakeup_callback(self.handle, nil, nil)
            // Balance the retain handed to the wakeup `ctx` in `init`. The enclosing
            // closure keeps its own strong reference for the rest of this block.
            Unmanaged.passUnretained(self).release()
            self.continuation.finish()
            mpv_terminate_destroy(self.handle)
        }
    }

    // MARK: - Render context (GL thread)

    /// Creates the libmpv OpenGL render context, binding it to this handle. Call once, on the
    /// thread that owns the GL context (the `CAOpenGLLayer` draw thread), after that context is
    /// current. `updateCallback` fires whenever mpv has a new frame to draw — it runs on an
    /// arbitrary mpv thread, so it must hop to the GL/main thread before requesting a redraw.
    func createRenderContext(updateCallback: @escaping () -> Void) {
        guard renderContext == nil else { return }
        renderUpdate = updateCallback

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in mpvGLProcAddress(name) },
            get_proc_address_ctx: nil
        )

        var created: OpaquePointer?
        "opengl".withCString { apiType in
            withUnsafeMutablePointer(to: &initParams) { initPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                     data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                     data: UnsafeMutableRawPointer(initPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                mpv_render_context_create(&created, handle, &params)
            }
        }
        guard let created else { return }
        renderContext = created

        mpv_render_context_set_update_callback(created, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVClient>.fromOpaque(ctx).takeUnretainedValue().renderUpdate?()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Renders the current frame into `fbo` (the framebuffer CoreAnimation bound for the
    /// layer) at the given pixel size. Call on the GL draw thread with the context current.
    /// A no-op for the audio/`vo=null` instances, which have no render context.
    func render(fbo: Int32, width: Int32, height: Int32) {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return }
        var target = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flipY: CInt = 1   // GL's origin is bottom-left; flip to match the layer.
        withUnsafeMutablePointer(to: &target) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO,
                                     data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y,
                                     data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
    }

    /// Tells mpv the buffer was presented, so it can pace presentation timing. Call after the
    /// layer flushes its drawable.
    func reportSwap() {
        renderLock.lock()
        defer { renderLock.unlock() }
        if let renderContext { mpv_render_context_report_swap(renderContext) }
    }

    /// Detaches the update callback and frees the render context. Idempotent. Must run before
    /// `mpv_terminate_destroy`; `shutdown()` calls it for that reason.
    func freeRenderContext() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        renderUpdate = nil
    }

    // MARK: - Commands

    /// Loads `path`, optionally resuming at `startingAt` seconds.
    func loadFile(_ path: String, startingAt position: TimeInterval? = nil) {
        queue.async {
            guard !self.isTerminated else { return }   // handle already destroyed by shutdown
            if let position {
                command(self.handle, "loadfile", path, "replace", "0", "start=\(position)")
            } else {
                command(self.handle, "loadfile", path, "replace")
            }
        }
    }

    func play() { setProperty("pause", flag: false) }
    func pause() { setProperty("pause", flag: true) }

    /// Stops playback and clears the playlist (mpv emits `end-file` with reason `stop`).
    func stop() {
        queue.async {
            guard !self.isTerminated else { return }   // handle already destroyed by shutdown
            command(self.handle, "stop")
        }
    }

    /// Seeks to an absolute position in seconds.
    func seek(to seconds: TimeInterval) {
        queue.async {
            guard !self.isTerminated else { return }   // handle already destroyed by shutdown
            command(self.handle, "seek", String(seconds), "absolute")
        }
    }

    /// Seeks by a relative offset in seconds (may be negative).
    func seek(by seconds: TimeInterval) {
        queue.async {
            guard !self.isTerminated else { return }   // handle already destroyed by shutdown
            command(self.handle, "seek", String(seconds), "relative")
        }
    }

    // MARK: - Properties

    /// Playback volume, 0–100. Reads are synchronous; writes are dispatched.
    var volume: Double {
        get {
            queue.sync {
                guard !isTerminated else { return 0 }   // handle already destroyed by shutdown
                var value: Double = 0
                mpv_get_property(self.handle, "volume", MPV_FORMAT_DOUBLE, &value)
                return value
            }
        }
        set { setProperty("volume", double: newValue) }
    }

    /// Whether the current file loops forever (`loop-file=inf`).
    var isLooping: Bool {
        get {
            queue.sync {
                guard !isTerminated else { return false }   // handle already destroyed by shutdown
                guard let raw = mpv_get_property_string(self.handle, "loop-file") else { return false }
                defer { mpv_free(raw) }
                let value = String(cString: raw)
                return value != "no" && value != "0"
            }
        }
        set {
            queue.async {
                guard !self.isTerminated else { return }   // handle already destroyed by shutdown
                mpv_set_property_string(self.handle, "loop-file", newValue ? "inf" : "no")
            }
        }
    }

    // MARK: - Event draining (serial queue)

    /// Scheduled by the wakeup callback; drains all pending events on `queue`.
    fileprivate func drainEvents() {
        guard !isTerminated else { return }   // handle already destroyed by shutdown
        while true {
            guard let raw = mpv_wait_event(handle, 0) else { break }
            let event = raw.pointee
            if event.event_id == MPV_EVENT_NONE { break }
            if let translated = translate(event) {
                continuation.yield(translated)
            }
            if event.event_id == MPV_EVENT_SHUTDOWN {
                continuation.finish()
                break
            }
        }
    }

    private func translate(_ event: mpv_event) -> MPVEvent? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: prop.name)
            switch name {
            case "time-pos":
                return .timePosition(doubleValue(prop))
            case "duration":
                return .duration(doubleValue(prop))
            case "pause":
                return .pausedChanged(flagValue(prop))
            case "eof-reached":
                // Only the rising edge matters; eof-reached also clears to false on a seek-back.
                return flagValue(prop) ? .endFile(.eof) : nil
            case "dwidth":
                return .videoWidth(intValue(prop))
            case "dheight":
                return .videoHeight(intValue(prop))
            default:
                return nil
            }

        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded

        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return .endFile(.other) }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            return .endFile(endReason(end.reason))

        case MPV_EVENT_SHUTDOWN:
            return .shutdown

        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return nil }
            let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = String(cString: msg.prefix)
            let level = String(cString: msg.level)
            let text = String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return .logMessage("[\(prefix)/\(level)] \(text)")

        default:
            return nil
        }
    }

    // MARK: - C helpers (serial queue / init only)

    private func setOption(_ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    private func setProperty(_ name: String, flag: Bool) {
        queue.async {
            guard !self.isTerminated else { return }   // handle already destroyed by shutdown
            var value: Int32 = flag ? 1 : 0
            mpv_set_property(self.handle, name, MPV_FORMAT_FLAG, &value)
        }
    }

    private func setProperty(_ name: String, double: Double) {
        queue.async {
            guard !self.isTerminated else { return }   // handle already destroyed by shutdown
            var value = double
            mpv_set_property(self.handle, name, MPV_FORMAT_DOUBLE, &value)
        }
    }

    /// Reply-ID constants for `mpv_observe_property` (currently informational; events are
    /// dispatched by property name).
    private enum PropertyID {
        static let timePos: UInt64 = 1
        static let duration: UInt64 = 2
        static let pause: UInt64 = 3
        static let eofReached: UInt64 = 4
        static let dwidth: UInt64 = 5
        static let dheight: UInt64 = 6
    }
}

// MARK: - Errors

nonisolated enum MPVError: Error {
    case createFailed
    case initializeFailed
}

// MARK: - Free functions (no captured Swift context)

private extension MPVClient {
    nonisolated func scheduleDrain() {
        queue.async { [weak self] in self?.drainEvents() }
    }
}

/// Resolves an OpenGL function pointer by name for libmpv's `get_proc_address`. Looks symbols
/// up in the system OpenGL framework, the approach mpv's own macOS examples use. Capture-free
/// so it can be passed as a C function pointer.
private nonisolated func mpvGLProcAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name,
          let framework = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    else { return nil }
    let symbol = String(cString: name) as CFString
    return CFBundleGetFunctionPointerForName(framework, symbol)
}

/// Variadic `mpv_command` shim: builds the `NULL`-terminated `argv` libmpv expects.
private nonisolated func command(_ handle: OpaquePointer, _ args: String...) {
    let duplicated = args.map { strdup($0) }          // owned copies, freed below
    defer { duplicated.forEach { free($0) } }
    var argv: [UnsafePointer<CChar>?] = duplicated.map { UnsafePointer($0) }
    argv.append(nil)
    argv.withUnsafeMutableBufferPointer { buffer in
        _ = mpv_command(handle, buffer.baseAddress)
    }
}

private nonisolated func doubleValue(_ prop: mpv_event_property) -> Double? {
    guard prop.format == MPV_FORMAT_DOUBLE, let data = prop.data else { return nil }
    return data.assumingMemoryBound(to: Double.self).pointee
}

private nonisolated func intValue(_ prop: mpv_event_property) -> Int? {
    guard prop.format == MPV_FORMAT_INT64, let data = prop.data else { return nil }
    return Int(data.assumingMemoryBound(to: Int64.self).pointee)
}

private nonisolated func flagValue(_ prop: mpv_event_property) -> Bool {
    guard prop.format == MPV_FORMAT_FLAG, let data = prop.data else { return false }
    return data.assumingMemoryBound(to: Int32.self).pointee != 0
}

private nonisolated func endReason(_ reason: mpv_end_file_reason) -> MPVEvent.EndReason {
    switch reason {
    case MPV_END_FILE_REASON_EOF: return .eof
    case MPV_END_FILE_REASON_STOP: return .stop
    case MPV_END_FILE_REASON_QUIT: return .quit
    case MPV_END_FILE_REASON_ERROR: return .error
    default: return .other
    }
}
