//
//  WindowNotificationBridgeTests.swift
//  ShuTaPlaTests
//
//  The bridge that reports its hosting window's notifications: that it reports the names it
//  observes for the one window it is in, and follows the view to another window. Notifications
//  are posted by hand, so no window closes or shows a sheet.
//

import Testing
import AppKit
@testable import ShuTaPla

@MainActor
@Suite struct WindowNotificationBridgeTests {

    @Test func aCloseOfItsOwnWindowIsReported() {
        let window = offscreenWindow()
        let other = offscreenWindow()
        let closes = Recorder()
        let view = observingView([NSWindow.willCloseNotification], closes)
        window.contentView?.addSubview(view)

        post(NSWindow.willCloseNotification, other)
        #expect(closes.names.isEmpty)

        post(NSWindow.willCloseNotification, window)
        #expect(closes.names == [NSWindow.willCloseNotification])
        #expect(closes.windows == [window])
    }

    @Test func eachObservedNameIsReportedAndNoOther() {
        let window = offscreenWindow()
        let other = offscreenWindow()
        let reports = Recorder()
        let names = [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification]
        let view = observingView(names, reports)
        window.contentView?.addSubview(view)

        post(NSWindow.willBeginSheetNotification, other)
        post(NSWindow.didEndSheetNotification, other)
        post(NSWindow.willCloseNotification, window)
        #expect(reports.names.isEmpty)

        post(NSWindow.willBeginSheetNotification, window)
        post(NSWindow.didEndSheetNotification, window)
        #expect(reports.names == names)
    }

    @Test func theObservationFollowsTheViewToAnotherWindow() {
        let first = offscreenWindow()
        let second = offscreenWindow()
        let closes = Recorder()
        let view = observingView([NSWindow.willCloseNotification], closes)
        first.contentView?.addSubview(view)

        view.removeFromSuperview()
        second.contentView?.addSubview(view)
        post(NSWindow.willCloseNotification, first)
        #expect(closes.names.isEmpty)

        post(NSWindow.willCloseNotification, second)
        #expect(closes.windows == [second])
    }

    private func observingView(_ names: [Notification.Name], _ recorder: Recorder) -> WindowNotificationBridge.ObservingView {
        let view = WindowNotificationBridge.ObservingView(names: names)
        view.onNotification = { name, window in
            recorder.names.append(name)
            recorder.windows.append(window)
        }
        return view
    }

    private func post(_ name: Notification.Name, _ window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    /// Far off screen, so nothing a test does puts anything in front of whoever is running it.
    private func offscreenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
    }
}

/// A reference box so a test can collect the reports made from an escaping closure.
@MainActor private final class Recorder {
    var names: [Notification.Name] = []
    var windows: [NSWindow] = []
}
