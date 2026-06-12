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
}
