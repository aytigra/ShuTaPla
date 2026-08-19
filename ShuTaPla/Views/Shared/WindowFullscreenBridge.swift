//
//  WindowFullscreenBridge.swift
//  ShuTaPla
//
//  A zero-size bridge that has player mode claim the hosting window's fullscreen
//  state — the one window property SwiftUI has no equivalent for. Mounted once on the
//  main content view and driven as a level: the claim is a function of the current
//  mode, so it holds for a window that outlives every view showing it. The bridge
//  only says whether the claim is on; the window's `FullscreenController` owns the
//  animated transition, restores what the window was when the claim is released, and
//  reconciles rapid changes without flicker or stale state.
//
//  Only changes of that level are forwarded, and a claim is what player mode holds —
//  not a state it enforces. A window taken fullscreen by hand outside player mode is
//  left alone, and SwiftUI's repeated update calls can't undo it.
//
//  The request is made on a fresh run-loop turn, never during the layout pass, so it
//  never resizes the hosting window while SwiftUI is mid-render (which AppKit reports
//  as a reentrant layout).
//

import SwiftUI
import AppKit

struct WindowFullscreenBridge: NSViewRepresentable {
    /// Whether the hosting window's fullscreen state is claimed.
    let isFullscreen: Bool

    func makeNSView(context: Context) -> FullscreenRequestingView {
        FullscreenRequestingView { window, fullscreen in
            window.fullscreenController.setClaimed(fullscreen)
        }
    }

    func updateNSView(_ nsView: FullscreenRequestingView, context: Context) {
        nsView.request(isFullscreen)
    }

    /// A zero-size view that passes the requested state to the window it is attached to. The
    /// request is a closure so tests can observe it: the real one reaches `FullscreenController`,
    /// whose transition needs a screen and would create a Space.
    @MainActor
    final class FullscreenRequestingView: NSView {
        private let apply: (NSWindow, Bool) -> Void

        /// What the level says now, and what was last told to which window — `nil` until the first
        /// of each. Keeping both is what makes this a level: a window hears only about differences,
        /// however often SwiftUI updates the view. The delivery is keyed on its window because it
        /// is a fact about *that* window: arriving at another one is a difference too, since the
        /// new window has never heard the level.
        private var requested: Bool?
        private var delivered: Bool?
        private weak var deliveredWindow: NSWindow?

        init(apply: @escaping (NSWindow, Bool) -> Void) {
            self.apply = apply
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func request(_ fullscreen: Bool) {
            guard requested != fullscreen else { return }
            requested = fullscreen
            schedule()
        }

        /// A request made before the view had a window was not delivered — the state is kept, so
        /// attaching is simply the next chance to deliver it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        /// Hops off the current layout/render pass before changing window geometry. Reads the state
        /// when it fires rather than capturing it, so a burst of changes settles on the last one.
        private func schedule() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, let requested,
                      requested != delivered || window !== deliveredWindow else { return }
                delivered = requested
                deliveredWindow = window
                apply(window, requested)
            }
        }
    }
}
