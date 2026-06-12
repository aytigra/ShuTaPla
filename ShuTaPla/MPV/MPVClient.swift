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
            /// Render video through `gpu-next` on Vulkan/MoltenVK into an embedded view.
            case gpuNext
            /// No video output (`--vo=null`) — used by the audio instance and by tests.
            case null
        }

        var videoOutput: VideoOutput
        var hardwareDecoding: Bool
        var initialVolume: Double

        static let video = Configuration(videoOutput: .gpuNext, hardwareDecoding: true, initialVolume: 100)
        static let audio = Configuration(videoOutput: .null, hardwareDecoding: false, initialVolume: 100)
    }

    /// `nonisolated(unsafe)`: the handle is non-`Sendable`, but every access is serialized
    /// through `queue`, which is the safety invariant this type upholds. The annotation lets it
    /// be captured by the `@Sendable` `queue.async`/`sync` closures that enforce that serialization.
    private nonisolated(unsafe) let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.aytigra.ShuTaPla.mpv")
    private let continuation: AsyncStream<MPVEvent>.Continuation

    /// The single event stream for this instance. Consume it once from the owning engine.
    let events: AsyncStream<MPVEvent>

    // MARK: - Lifecycle

    /// Creates and initializes an mpv instance.
    ///
    /// - Parameters:
    ///   - configuration: output/decoding/volume options applied before `mpv_initialize`.
    ///   - wid: optional pointer to the host `NSView` (its `CAMetalLayer` is the render
    ///     surface). Must be supplied before initialization for the video output to embed,
    ///     so it is passed here rather than attached later. `nil` for audio and tests.
    /// - Throws: `MPVError` if the handle cannot be created or initialized.
    init(configuration: Configuration, wid: UnsafeMutableRawPointer? = nil) throws {
        guard let handle = mpv_create() else { throw MPVError.createFailed }
        self.handle = handle

        var continuation: AsyncStream<MPVEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation

        // Vulkan discovers MoltenVK as an ICD; point the loader at the bundled manifest
        // before mpv (via libplacebo) brings up the Vulkan context.
        MPVClient.configureVulkanICD()

        // --- options that must be set before mpv_initialize ---
        switch configuration.videoOutput {
        case .gpuNext:
            setOption("vo", "gpu-next")
            setOption("gpu-api", "vulkan")
            setOption("gpu-context", "moltenvk")
            setOption("hwdec", configuration.hardwareDecoding ? "auto-safe" : "no")
            setOption("target-colorspace-hint", "yes")   // HDR pass-through to EDR displays
            if let wid {
                var value = Int64(Int(bitPattern: wid))
                mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &value)
            }
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

        // Observe the properties the engines mirror as UI state.
        mpv_observe_property(handle, PropertyID.timePos, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, PropertyID.duration, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, PropertyID.pause, "pause", MPV_FORMAT_FLAG)
        // With keep-open=yes mpv holds the last frame and signals the natural end by flipping
        // eof-reached rather than emitting END_FILE, so this is the engine's "advance" trigger.
        mpv_observe_property(handle, PropertyID.eofReached, "eof-reached", MPV_FORMAT_FLAG)

        // Route mpv's wakeups onto our serial drain. The callback fires on an mpv-internal
        // thread; it must be a capture-free literal closure to form a C function pointer, so it
        // recovers `self` from the registered `ctx` and only schedules a drain.
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVClient>.fromOpaque(ctx).takeUnretainedValue().scheduleDrain()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Tears the instance down: stops wakeups, finishes the event stream, and destroys the
    /// handle on `queue`. Safe to call once; further commands become no-ops at the C layer.
    func shutdown() {
        queue.async {
            mpv_set_wakeup_callback(self.handle, nil, nil)
            self.continuation.finish()
            mpv_terminate_destroy(self.handle)
        }
    }

    // MARK: - Commands

    /// Loads `path`, optionally resuming at `startingAt` seconds.
    func loadFile(_ path: String, startingAt position: TimeInterval? = nil) {
        queue.async {
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
        queue.async { command(self.handle, "stop") }
    }

    /// Seeks to an absolute position in seconds.
    func seek(to seconds: TimeInterval) {
        queue.async { command(self.handle, "seek", String(seconds), "absolute") }
    }

    /// Seeks by a relative offset in seconds (may be negative).
    func seek(by seconds: TimeInterval) {
        queue.async { command(self.handle, "seek", String(seconds), "relative") }
    }

    // MARK: - Properties

    /// Playback volume, 0–100. Reads are synchronous; writes are dispatched.
    var volume: Double {
        get {
            queue.sync {
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
                guard let raw = mpv_get_property_string(self.handle, "loop-file") else { return false }
                defer { mpv_free(raw) }
                let value = String(cString: raw)
                return value != "no" && value != "0"
            }
        }
        set {
            queue.async {
                mpv_set_property_string(self.handle, "loop-file", newValue ? "inf" : "no")
            }
        }
    }

    // MARK: - Event draining (serial queue)

    /// Scheduled by the wakeup callback; drains all pending events on `queue`.
    fileprivate func drainEvents() {
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
            return .logMessage(String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines))

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
            var value: Int32 = flag ? 1 : 0
            mpv_set_property(self.handle, name, MPV_FORMAT_FLAG, &value)
        }
    }

    private func setProperty(_ name: String, double: Double) {
        queue.async {
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
    }
}

// MARK: - Vulkan ICD discovery

private extension MPVClient {
    /// Points the Vulkan loader at the MoltenVK ICD manifest bundled next to `libMoltenVK.dylib`
    /// in the app's `Frameworks/`. Runs exactly once, before the first Vulkan context is created.
    /// A no-op in dev builds where the manifest hasn't been bundled (mpv then falls back to the
    /// system loader's default search, if any).
    nonisolated static let vulkanICDConfigured: Void = {
        guard let manifest = Bundle.main.url(forResource: "MoltenVK_icd", withExtension: "json") else { return }
        // VK_DRIVER_FILES is the current loader variable; VK_ICD_FILENAMES is the legacy alias.
        setenv("VK_DRIVER_FILES", manifest.path, 1)
        setenv("VK_ICD_FILENAMES", manifest.path, 1)
    }()

    nonisolated static func configureVulkanICD() { _ = vulkanICDConfigured }
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
