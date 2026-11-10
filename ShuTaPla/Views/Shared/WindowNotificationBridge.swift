//
//  WindowNotificationBridge.swift
//  ShuTaPla
//
//  A zero-size bridge that reports the named notifications of its hosting window. It observes
//  only the one window it is in, so the auxiliary Settings window, a separate Scene, never
//  triggers it.
//

import SwiftUI
import AppKit

struct WindowNotificationBridge: NSViewRepresentable {
    let names: [Notification.Name]
    let onNotification: (_ name: Notification.Name, _ window: NSWindow) -> Void

    init(_ names: [Notification.Name], onNotification: @escaping (Notification.Name, NSWindow) -> Void) {
        self.names = names
        self.onNotification = onNotification
    }

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView(names: names)
        view.onNotification = onNotification
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onNotification = onNotification
    }

    /// A zero-size view that observes `names` for the one window it attaches to.
    @MainActor
    final class ObservingView: NSView {
        let names: [Notification.Name]
        var onNotification: (Notification.Name, NSWindow) -> Void = { _, _ in }

        init(names: [Notification.Name]) {
            self.names = names
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            for name in names {
                center.addObserver(self, selector: #selector(received), name: name, object: window)
            }
        }

        @objc private func received(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            onNotification(notification.name, window)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
