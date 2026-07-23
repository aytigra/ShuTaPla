import Foundation

/// A value-type projection of the libmpv events the app cares about.
///
/// Events originate on `MPVClient`'s serial queue (driven by `mpv_wait_event`) and are
/// delivered to the owning playback engine on `MainActor` through an `AsyncStream`.
/// Every payload is a value type so the enum is `Sendable` and crosses that boundary safely.
nonisolated enum MPVEvent: Sendable, Equatable {
    /// The playback position changed (observed `time-pos`, seconds). `nil` clears the value
    /// (e.g. no file loaded).
    case timePosition(TimeInterval?)

    /// The current file's duration became known or changed (observed `duration`, seconds).
    case duration(TimeInterval?)

    /// The pause state changed (observed `pause`).
    case pausedChanged(Bool)

    /// The decoded video's display width / height became known (observed `dwidth` / `dheight`,
    /// already corrected for anamorphic pixels and rotation). Arrive as a pair around file load;
    /// `nil` while no video is decoded. Together they give the preview card its aspect ratio.
    case videoWidth(Int?)
    case videoHeight(Int?)

    /// A file finished loading and playback metadata is available (`MPV_EVENT_FILE_LOADED`).
    case fileLoaded

    /// Playback (re)started after a seek or load settled (`MPV_EVENT_PLAYBACK_RESTART`),
    /// carrying the settled `time-pos` and the render-update count, both read at that instant.
    /// The engine's forward-step end-of-file detection compares them to the position and count
    /// the step was issued from: a settled position not ahead, or a count that did not move
    /// (no new video frame across the step), each mean the file has ended.
    case playbackRestart(TimeInterval, frames: UInt64)

    /// The end of the current file was reached (`MPV_EVENT_END_FILE`).
    /// `reason` distinguishes natural EOF from a stop/error/quit.
    case endFile(EndReason)

    /// mpv is fully shut down (`MPV_EVENT_SHUTDOWN`); no further events will arrive.
    case shutdown

    /// A non-fatal log/diagnostic surfaced by mpv. Carried for debugging only.
    case logMessage(String)

    /// Why the current file ended.
    nonisolated enum EndReason: Sendable, Equatable {
        /// Reached the natural end of the file.
        case eof
        /// Stopped by an explicit `stop` command.
        case stop
        /// Replaced by loading a different file.
        case quit
        /// Playback aborted by an error.
        case error
        /// Reason mpv reported that does not map to the cases above.
        case other
    }
}
