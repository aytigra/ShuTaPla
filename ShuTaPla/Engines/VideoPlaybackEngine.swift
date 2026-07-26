//
//  VideoPlaybackEngine.swift
//  ShuTaPla
//
//  The video channel. It is an `MPVPlaybackEngine` whose client renders into an
//  app-owned `MPVVideoView` through the libmpv OpenGL render API. The engine creates
//  the client (`--vo=libmpv`) and the view, then connects them; the view creates the
//  render context once its OpenGL context exists. mpv never opens a window of its own.
//

import Foundation
import AppKit

@MainActor
final class VideoPlaybackEngine: MPVPlaybackEngine {

    /// The surface mpv renders into, hosted in SwiftUI via `NSViewRepresentable`.
    let renderView: MPVVideoView

    init() throws {
        let view = MPVVideoView(frame: .zero)
        self.renderView = view
        try super.init(configuration: .video)
        view.attach(client)
    }

    /// Pre-configures colour output from the file's cached colour tags before a frame is decoded,
    /// so an HDR file opens straight to its PQ layer instead of flashing SDR for the first frames
    /// (and a following SDR file resets to SDR at once, not on its first params). Cached tags are
    /// best-effort — `nil` for a never-displayed file, or a determined SDR — and the authoritative
    /// pass on live `video-params` (the base engine's `.videoWidth` decode signal) corrects the
    /// decision either way.
    override func load(_ file: PlaylistFile?, resource: String, startingAt position: TimeInterval? = nil) {
        super.load(file, resource: resource, startingAt: position)
        applyColorOutput(gamma: file?.hdrGamma, primaries: file?.hdrPrimaries)
    }

    /// Decides the output config from the given transfer/primaries and the hosting screen's EDR
    /// headroom, then applies it to both mpv (`target-*`) and the layer. In the render-API path
    /// mpv can't see that our layer is EDR-capable, so without this it tone-maps HDR down to SDR.
    /// The base engine reads a file's decoded `video-params` once when decode comes up and drives
    /// this override authoritatively; `load` pre-applies it from the file's cached tags.
    override func applyColorOutput(gamma: String?, primaries: String?) {
        let supportsEDR = (renderView.window?.screen ?? NSScreen.main)?.supportsEDR ?? false
        let config = HDRVideoConfig.decide(
            gamma: gamma ?? "", primaries: primaries ?? "", displaySupportsEDR: supportsEDR)
        client.setStringProperty("target-prim", config.targetPrimaries)
        client.setStringProperty("target-trc", config.targetTransfer)
        client.setStringProperty("target-peak", config.targetPeak)
        renderView.apply(config)
    }
}
