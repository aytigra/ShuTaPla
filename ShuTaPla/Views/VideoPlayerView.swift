//
//  VideoPlayerView.swift
//  ShuTaPla
//
//  Hosts the video engine's `MPVVideoView` in SwiftUI. mpv renders into the view's
//  OpenGL layer through the libmpv render API, so this representable only surfaces the
//  engine's existing view rather than creating or drawing one.
//

import SwiftUI
import AppKit

struct VideoPlayerView: NSViewRepresentable {
    @Environment(PlaybackCoordinator.self) private var coordinator

    func makeNSView(context: Context) -> NSView {
        coordinator.videoRenderView ?? NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
