//
//  VideoPlaybackEngine.swift
//  ShuTaPla
//
//  The video channel. It is an `MPVPlaybackEngine` whose client renders into an
//  embedded `MPVMetalView` via gpu-next on Vulkan/MoltenVK. The view must exist
//  before the client (mpv needs its `wid` at initialization), so it is created
//  first and its pointer handed to the base initializer.
//

import Foundation
import AppKit

@MainActor
final class VideoPlaybackEngine: MPVPlaybackEngine {

    /// The surface mpv renders into, hosted in SwiftUI via `NSViewRepresentable`.
    let renderView: MPVMetalView

    init() throws {
        let view = MPVMetalView(frame: .zero)
        self.renderView = view
        try super.init(configuration: .video, wid: view.windowID)
    }
}
