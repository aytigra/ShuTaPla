//
//  FullscreenView.swift
//  ShuTaPla
//
//  A zero-size bridge that drives the hosting window into fullscreen while it is
//  in the view tree and back out when it leaves — the mechanism the window has no
//  SwiftUI equivalent for. Player mode mounts it; returning to Manager unmounts
//  it, which exits fullscreen. (Animated, polished transitions are Task 18.)
//

import SwiftUI
import AppKit

struct FullscreenView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.exitFullscreen()
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var didEnter = false

        /// The window may not be attached the instant the view is made, so poll a
        /// few times before giving up.
        func attach(_ view: NSView) {
            self.view = view
            enterWhenReady(attempt: 0)
        }

        private func enterWhenReady(attempt: Int) {
            guard !didEnter else { return }
            if let window = view?.window {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                didEnter = true
            } else if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.enterWhenReady(attempt: attempt + 1)
                }
            }
        }

        func exitFullscreen() {
            guard let window = view?.window, window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }
}
