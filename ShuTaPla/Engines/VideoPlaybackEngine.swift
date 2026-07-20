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

    /// Reconfigures colour output when a file's decoded video params first arrive. `dwidth`
    /// (`.videoWidth`) turning positive is that signal — decode is up, so `video-params/*` are
    /// valid — and it is stable per file, so this runs once per file.
    override func handle(_ event: MPVEvent) {
        super.handle(event)
        if case .videoWidth(let width?) = event, width > 0 { configureColorOutput() }
    }

    /// Reads the decoded transfer/primaries and the hosting screen's EDR headroom, decides the
    /// output config, and applies it to both mpv (`target-*`) and the layer. In the render-API path
    /// mpv can't see that our layer is EDR-capable, so without this it tone-maps HDR down to SDR.
    private func configureColorOutput() {
        let screen = renderView.window?.screen ?? NSScreen.main
        let supportsEDR = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let config = HDRVideoConfig.decide(
            gamma: client.stringProperty("video-params/gamma") ?? "",
            primaries: client.stringProperty("video-params/primaries") ?? "",
            displaySupportsEDR: supportsEDR)
        client.setStringProperty("target-prim", config.targetPrimaries)
        client.setStringProperty("target-trc", config.targetTransfer)
        client.setStringProperty("target-peak", config.targetPeak)
        renderView.apply(config)
    }
}
